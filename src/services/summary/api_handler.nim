import std/[os, logging]
import chronos
import chronos/transports/stream
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

type
  Summary* = object
    default*: ProcessedData
    fallback*: ProcessedData

  ProcessedData* = object
    totalRequests*: uint64
    totalAmount*: float32

proc newProcessedData*(count: uint64, amount: uint64): ProcessedData =
  ProcessedData(
    totalRequests: count,
    totalAmount: amount.float32 / 100.0
  )

proc newSummary*(summary: array[2, tuple[requests: uint64, amount: uint64]]): Summary =
  Summary(
    default: newProcessedData(summary[0].requests, summary[0].amount),
    fallback: newProcessedData(summary[1].requests, summary[1].amount)
  )

proc getSummary*(query: tuple[fromTime, toTime: int64], buf: seq[byte]): Future[tuple[responseData: seq[byte], length: int]] {.async: (raises: [CatchableError, CancelledError, Exception]).} =
  let workerSocket = getEnv("WORKER_SOCKET", "/tmp/worker.sock")
  safeDebug "[api.summary] connecting to worker at " & workerSocket
  try:
    # Create fresh connection
    let transport = await connect(initTAddress(workerSocket))
    safeDebug "[api.summary] connected"
    defer:
      try:
        transport.close()
        safeDebug "[api.summary] transport closed"
      except:
        discard

    # Create request JSON (no trailing newline necessary)
    let requestJson = "{\"type\":\"get_summary\",\"data\":{\"fromTime\":" & $query.fromTime & ",\"toTime\":" & $query.toTime & "}}"
    discard await transport.write(requestJson)
    safeDebug "[api.summary] wrote " & $requestJson.len & " bytes"

    # Read until EOF (worker closes after write). Use a reasonably sized buffer with accumulation.
    var bufAcc = newSeq[byte](0)
    var tmp = newSeq[byte](512)
    while true:
      let n = await transport.readOnce(addr tmp[0], tmp.len)
      if n <= 0:
        safeDebug "[api.summary] EOF reached"
        break
      let oldLen = bufAcc.len
      bufAcc.setLen(oldLen + n)
      copyMem(addr bufAcc[oldLen], addr tmp[0], n)
      # Minimal logging to avoid overhead during bursts
    return (bufAcc, bufAcc.len)
  except CatchableError as e:
    safeWarn "[api.summary] exception: " & e.msg
    raise
