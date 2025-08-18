import std/[os, strutils, logging, times, uri]
import chronos
import chronos/transports/stream
import results
import ../services/payment/api_handler
import ../services/summary/api_handler as summary_handler
import ../shared/utilities

# Safe logging helpers to avoid exceptions from logging in async procs
template safeDebug(msg: string) =
  try:
    debug msg
  except:
    discard

template safeWarn(msg: string) =
  try:
    warn msg
  except:
    discard

# Forward declarations
proc sendOk(transport: StreamTransport) {.async: (raises: [CatchableError, CancelledError]).}
proc handlePayment(buf: seq[byte]) {.async: (raises: [CatchableError, CancelledError]).}
proc handlePaymentBody(jsonBody: string) {.async: (raises: [CatchableError, CancelledError]).}
proc getSummary(buf: seq[byte]): Future[tuple[responseData: seq[byte], length: int]] {.async: (raises: [CatchableError, CancelledError]).}
proc getQuery(buf: seq[byte]): tuple[fromTime, toTime: int64] {.raises: [], gcsafe.}

proc handleRequest(server: StreamServer, transport: StreamTransport) {.async: (raises: [CatchableError, CancelledError]).} =
  try:
    safeDebug "Request received!"

    var buf = newSeq[byte](4096)
    var totalRead = await transport.readOnce(addr buf[0], buf.len)
    if totalRead == 0:
      safeDebug "No data read"
      return
    buf.setLen(totalRead)
    let now = getTime()

    let firstByte = buf[0]
    if firstByte == ord('G'):
      let s = cast[string](buf)
      if s.startsWith("GET /payments-summary"):
        let (responseData, responseLen) = await getSummary(buf)
        let bodyLen = $responseLen
        let httpHeader = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " & bodyLen & "\r\n\r\n"
        discard await transport.write(httpHeader)
        if responseLen > 0:
          discard await transport.write(addr responseData[0], responseLen)
      else:
        discard await transport.write("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!")

    elif firstByte == ord('P'):
      var headerEnd = cast[string](buf).find("\r\n\r\n")
      while headerEnd < 0:
        let oldLen = buf.len
        buf.setLen(oldLen * 2)
        let n = await transport.readOnce(addr buf[totalRead], oldLen)
        if n <= 0: break
        totalRead += n
        buf.setLen(totalRead)
        headerEnd = cast[string](buf).find("\r\n\r\n")

      let fullStr = cast[string](buf[0 ..< totalRead])
      let rn = fullStr.find("\r\n")
      let reqLine = if rn >= 0: fullStr[0 ..< rn] else: fullStr
      let parts = reqLine.split(' ')
      let path = if parts.len >= 2: parts[1] else: "/"

      if path == "/purge-payments":
        # Dev-only endpoint: always reply 200 even if purge transport has a hiccup
        try:
          await utilities.purge()
        except:
          discard
        await sendOk(transport)
      elif path == "/payments":
        var contentLength = 0
        if headerEnd >= 0:
          let headersStr = fullStr[0 ..< headerEnd]
          for line in headersStr.splitLines():
            let lower = line.toLowerAscii()
            if lower.startsWith("content-length:"):
              try:
                contentLength = line.split(':', 1)[1].strip.parseInt
              except:
                contentLength = 0
              break
        let bodyStart = (if headerEnd >= 0: headerEnd + 4 else: totalRead)
        var haveBody = totalRead - bodyStart
        if contentLength > 0 and haveBody < contentLength:
          var remaining = contentLength - haveBody
          if buf.len < totalRead + remaining:
            buf.setLen(totalRead + remaining)
          while remaining > 0:
            let n = await transport.readOnce(addr buf[totalRead], remaining)
            if n <= 0: break
            totalRead += n
            remaining -= n
            haveBody += n
        var badRequest = false
        var ok = false
        try:
          var body = ""
          if contentLength > 0 and bodyStart + contentLength <= totalRead:
            body = cast[string](buf[bodyStart ..< bodyStart + contentLength])
          if body.len > 0:
            let req = api_handler.parsePaymentRequest(body)
            ok = await api_handler.send(@[], req)
          else:
            var start = -1
            var stop = -1
            for i, b in buf:
              if b == ord('{'): start = i; break
            for i in countdown(buf.len - 1, 0):
              if buf[i] == ord('}'): stop = i; break
            if start >= 0 and stop >= 0:
              let reqJson = cast[string](buf[start..stop])
              let req = api_handler.parsePaymentRequest(reqJson)
              ok = await api_handler.send(buf, req)
        except CatchableError:
          badRequest = true
        if badRequest:
          discard await transport.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        else:
          if ok:
            discard await transport.write("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n")
          else:
            discard await transport.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
      else:
        discard await transport.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
    else:
      discard await transport.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")

  except CatchableError:
    try:
      discard await transport.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
    except:
      discard
  finally:
    try:
      await transport.closeWait()
    except:
      discard

proc sendOk(transport: StreamTransport) {.async: (raises: [CatchableError, CancelledError]).} =
  try:
    discard await transport.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
  except:
    discard

proc handlePayment(buf: seq[byte]) {.async: (raises: [CatchableError, CancelledError]).} =
  # Find JSON start and end
  var start = -1
  var stop = -1
  var reqJson = ""

  for i, b in buf:
    if b == ord('{'):
      start = i
      break

  for i in countdown(buf.len - 1, 0):
    if buf[i] == ord('}'):
      stop = i
      break

  if start >= 0 and stop >= 0:
    reqJson = cast[string](buf[start..stop])
  else:
    raise newException(CatchableError, "Invalid JSON body")
  let req = api_handler.parsePaymentRequest(reqJson)
  discard await api_handler.send(buf, req)

proc handlePaymentBody(jsonBody: string) {.async: (raises: [CatchableError, CancelledError]).} =
  let req = api_handler.parsePaymentRequest(jsonBody)
  discard await api_handler.send(@[], req)

proc toBytes(s: string): seq[byte] {.raises: [].} =
  ## Safe conversion from string to seq[byte]
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc emptySummaryPayload(): string =
  "{" &
    "\"default\":{\"totalRequests\":0,\"totalAmount\":0.0}," &
    "\"fallback\":{\"totalRequests\":0,\"totalAmount\":0.0}" &
  "}"

proc getSummary(buf: seq[byte]): Future[tuple[responseData: seq[byte], length: int]] {.async: (raises: [CatchableError, CancelledError]).} =
  try:
    let query = getQuery(buf)
    return await summary_handler.getSummary(query, buf)
  except CatchableError as e:
    safeWarn "[api] summary path failed: " & e.msg
    let fallback = emptySummaryPayload()
    let bytes = toBytes(fallback)
    return (bytes, bytes.len)
  except:
    safeWarn "[api] summary path failed: unknown exception"
    let fallback = emptySummaryPayload()
    let bytes = toBytes(fallback)
    return (bytes, bytes.len)

proc getQuery(buf: seq[byte]): tuple[fromTime, toTime: int64] {.raises: [], gcsafe.} =
  const DISTANT_FUTURE_MICROS = int64.high
  let s = cast[string](buf)
  let qIdx = s.find("/payments-summary")
  if qIdx < 0:
    return (0'i64, DISTANT_FUTURE_MICROS)
  # Extract query string after space following path
  let sp = s.find(' ', qIdx)
  var fromVal = ""
  var toVal = ""
  if sp > 0:
    let qMark = s.find('?', qIdx)
    if qMark > 0:
      let endPos = s.find(' ', qMark)
      let qs = if endPos > 0: s[qMark+1 ..< endPos] else: s[qMark+1 ..< s.len]
      for part in qs.split('&'):
        if part.len == 0: continue
        let kv = part.split('=')
        if kv.len == 2:
          if kv[0] == "from": fromVal = decodeUrl(kv[1])
          elif kv[0] == "to": toVal = decodeUrl(kv[1])
  var fromMicros = 0'i64
  var toMicros = DISTANT_FUTURE_MICROS
  try:
    if fromVal.len > 0:
      fromMicros = (parseTime(fromVal, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnixFloat() * 1_000_000).int64
  except:
    fromMicros = 0'i64
  try:
    if toVal.len > 0:
      toMicros = (parseTime(toVal, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnixFloat() * 1_000_000).int64
  except:
    toMicros = DISTANT_FUTURE_MICROS
  return (fromMicros, toMicros)

proc serve*(): Future[Result[void, ref CatchableError]] {.async.} =
  try:
    safeDebug "starting API"
    
    let apiN = getEnv("API_N", "")
    let socketPath = if apiN != "":
      "/var/run/api" & apiN & ".sock"
    else:
      "/tmp/api.sock"
    
    safeDebug "API socket path: " & socketPath
    
    # Remove existing socket file
    try:
      removeFile(socketPath)
    except OSError:
      discard
    
    let address = initTAddress(socketPath)
    
    # Create a closure wrapper for the handler
    let handler: StreamCallback = proc(server: StreamServer, transport: StreamTransport): Future[void] {.async.} =
      await handleRequest(server, transport)
    
    let server = createStreamServer(address, handler)
    
    try:
      setFilePermissions(socketPath, {fpUserRead, fpUserWrite, fpGroupRead, fpGroupWrite, fpOthersRead, fpOthersWrite})
    except OSError:
      discard
    
    server.start()
    safeDebug "binded to Unix socket on " & socketPath
    
    # Aguardar indefinidamente
    await server.join()
    
    return ok()
  except CatchableError as e:
    safeWarn "Failed to serve API: " & e.msg
    return err(e)
