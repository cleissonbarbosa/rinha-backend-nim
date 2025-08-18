import std/[os, times, json, logging]
import chronos
import chronos/apps/http/httpclient as httpc
import std/uri
import ../../core/domain

# Safe logging helpers to avoid exceptions in logging under constrained environments
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
  PPClient* = ref object
  PaymentProcessor = tuple[id: uint8, uri: string]

# Simple health cache (shared across PPClient instances)
type PPHealth = object
  failing: bool
  minResponseTime: int
  lastFetch: Time

var healthCache: array[2, PPHealth]
var healthInit: array[2, bool]

proc newPPClient*(): PPClient =
  PPClient()

proc getPaymentProcessors(): seq[PaymentProcessor] =
  let defaultProcessor = getEnv("PROCESSOR_DEFAULT", "http://payment-processor-default:8080")
  let fallbackProcessor = getEnv("PROCESSOR_FALLBACK", "http://payment-processor-fallback:8080")
  
  result = @[
    (1'u8, defaultProcessor),
    (2'u8, fallbackProcessor)
  ]

proc getPPToken(): string =
  # Prefer explicit envs, default to test runner's initial token 123
  result = getEnv("X_RINHA_TOKEN", "")
  if result.len == 0:
    result = getEnv("PP_TOKEN", "")
  if result.len == 0:
    result = getEnv("TOKEN", "123")

proc httpSend(session: httpc.HttpSessionRef, uri: string, payment: ProcessorPaymentRequest, processorId: uint8, timeoutMs: int): Future[Payment] {.async: (raises: [CatchableError]), gcsafe.} =
  let startTime = getTime()

  # Create the correct payload according to the instructions
  let payload = %*{
    "correlationId": payment.correlation_id,
    "amount": payment.amount,
    "requestedAt": payment.requested_at.format("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  }

  safeDebug "Sending to " & uri & "/payments - payload: " & $payload

  # Make the HTTP request using chronos async httpclient
  let headers = @[ ("Content-Type", "application/json"), ("Accept", "application/json"), ("X-Rinha-Token", getPPToken()) ]
  let url = uri & "/payments"
  # Build a POST request and fetch it
  let req = httpc.HttpClientRequestRef.post(session, url, headers = headers, body = $payload).valueOr:
    raise newException(CatchableError, "Failed to build HTTP request")
  # Keep processor latency budget under test timeout to prevent piling up
  let fetchFut = httpc.fetch(req)
  # Use Chronos Duration explicitly to avoid ambiguity with std/times TimeInterval
  let completed = await withTimeout(fetchFut, chronos.milliseconds(timeoutMs))
  if not completed:
    raise newException(CatchableError, "Payment processor timeout")
  let resp = fetchFut.read()
  
  safeDebug "Received response status: " & $resp.status

  let code = int(resp.status)
  if code < 200 or code >= 300:
    raise newException(CatchableError, "Payment processor returned error: " & $resp.status)

  let amount = (payment.amount * 100.0).uint64
  var reqMicros = 0'i64
  try:
    # Convert DateTime -> Time -> seconds (float) -> microseconds
    reqMicros = (payment.requested_at.toTime().toUnixFloat() * 1_000_000.0).int64
  except:
    reqMicros = 0'i64
  let requestedMicros = reqMicros
  result = Payment(
    amount: amount,
    requested_at: requestedMicros,
    processor_id: processorId
  )

proc fetchHealth(session: httpc.HttpSessionRef, uri: string, idx: int): Future[PPHealth] {.async: (raises: [CatchableError]), gcsafe.} =
  let nowT = getTime()
  if healthInit[idx] and (nowT - healthCache[idx].lastFetch) < initDuration(milliseconds = 5000):
    return healthCache[idx]
  # Fetch fresh health
  let url = uri & "/payments/service-health"
  let req = httpc.HttpClientRequestRef.get(session, url, headers = @[ ("Accept", "application/json") ]).valueOr:
    raise newException(CatchableError, "Failed to build health request")
  let fut = httpc.fetch(req)
  let ok = await withTimeout(fut, chronos.milliseconds(200))
  if not ok:
    # Assume failing on timeout
    let h = PPHealth(failing: true, minResponseTime: 10_000, lastFetch: nowT)
    healthCache[idx] = h
    healthInit[idx] = true
    return h
  let resp = fut.read()
  if int(resp.status) < 200 or int(resp.status) >= 300:
    let h = PPHealth(failing: true, minResponseTime: 10_000, lastFetch: nowT)
    healthCache[idx] = h
    healthInit[idx] = true
    return h
  # Parse health JSON body: { "failing": bool, "minResponseTime": int(ms) }
  var parsedOk = false
  var failing = true
  var minRt = 10_000
  try:
    let bodyBytes = resp.data
    if bodyBytes.len > 0:
      let bodyStr = cast[string](bodyBytes)
      let j = parseJson(bodyStr)
      failing = j["failing"].getBool()
      if j.hasKey("minResponseTime"):
        minRt = j["minResponseTime"].getInt()
      else:
        # default to a conservative 250ms if not provided
        minRt = 250
      parsedOk = true
  except CatchableError:
    parsedOk = false
  except:
    parsedOk = false
  let h = if parsedOk: PPHealth(failing: failing, minResponseTime: minRt, lastFetch: nowT)
          else: PPHealth(failing: true, minResponseTime: 10_000, lastFetch: nowT)
  healthCache[idx] = h
  healthInit[idx] = true
  return h

proc send*(ppClient: PPClient, session: httpc.HttpSessionRef, payment: PaymentRequest): Future[Payment] {.async: (raises: [CatchableError]).} =
  let processors = getPaymentProcessors()
  # Global budget to keep total under the k6 1500ms timeout including overheads
  let totalBudgetMs = block:
    try:
      parseInt(getEnv("PP_TOTAL_BUDGET_MS", "1400"))
    except:
      1400
  # Default attempt slice; remainder goes to fallback
  let firstAttemptMs = block:
    try:
      parseInt(getEnv("PP_FIRST_ATTEMPT_MS", "650"))
    except:
      650
  let minFallbackMs = block:
    try:
      parseInt(getEnv("PP_MIN_FALLBACK_MS", "350"))
    except:
      350
  let wallStart = getTime()
  # Optional small probe values (unused in the main two-tries-first-default flow but kept for future tuning)
  let oppMs = block:
    try:
      parseInt(getEnv("PP_OPPORTUNISTIC_MS", "250"))
    except:
      250
  let minShortMs = block:
    try:
      parseInt(getEnv("PP_MIN_SHORT_MS", "150"))
    except:
      150
  let secondAttemptMs = block:
    try:
      parseInt(getEnv("PP_SECOND_ATTEMPT_MS", "300"))
    except:
      300
  # If fallback health is failing/unknown, still allow a short opportunistic attempt
  let failingFallbackMs = block:
    try:
      parseInt(getEnv("PP_FAILING_FB_MS", "300"))
    except:
      300
  
  # Use the timestamp from the original request if available, otherwise now()
  var requestedAt = times.now().inZone(times.utc())
  if payment.requestedAtMicros > 0'i64:
    try:
      requestedAt = times.fromUnixFloat(payment.requestedAtMicros.float / 1_000_000.0).inZone(times.utc())
    except:
      requestedAt = times.now().inZone(times.utc())
  let processorRequest = ProcessorPaymentRequest(
    requested_at: requestedAt,
    amount: payment.amount,
    correlation_id: payment.correlationId
  )
  
  # Try processors with fallback
  # Attempt default first within its slice (skip if health suggests over budget)
  let (firstId, firstUri) = processors[0]
  var defHealth: PPHealth
  var healthOk = true
  try:
    defHealth = await fetchHealth(session, firstUri, 0)
  except CatchableError:
    healthOk = false
  let safetyMargin = block:
    try:
      parseInt(getEnv("PP_HEALTH_MARGIN_MS", "100"))
    except:
      100
  # Always prioritize default: try up to two times before considering fallback
  # Dynamically size the first attempt using health, but keep room for a second try and fallback
  let reserveSecondMin = 150
  var t1Timeout = min(firstAttemptMs, max(200, totalBudgetMs - minFallbackMs - reserveSecondMin))
  if healthOk and (not defHealth.failing):
    let suggested = defHealth.minResponseTime + safetyMargin
    if suggested > t1Timeout:
      t1Timeout = min(suggested, max(200, totalBudgetMs - minFallbackMs - reserveSecondMin))
      safeWarn "Adjusted default attempt #1 timeout to " & $t1Timeout & "ms based on default health"
  try:
    result = await httpSend(session, firstUri, processorRequest, firstId, t1Timeout)
    return result
  except CatchableError as e1:
    safeWarn "Default attempt #1 failed: " & e1.msg

  # Peek fallback health to decide whether to reserve time for it
  var elapsed = (getTime() - wallStart).inMilliseconds.int
  var remaining = max(totalBudgetMs - elapsed, 0)
  let (fbId, fbUri) = processors[1]
  var fbHealth: PPHealth
  var fbHealthOk = true
  try:
    fbHealth = await fetchHealth(session, fbUri, 1)
  except CatchableError:
    fbHealthOk = false
  var reservedForFallback = minFallbackMs
  if fbHealthOk:
    if not fbHealth.failing:
      reservedForFallback = max(minFallbackMs, fbHealth.minResponseTime + safetyMargin)
    else:
      # Health failing -> reserve a smaller budget to still attempt fallback briefly
      reservedForFallback = min(minFallbackMs, failingFallbackMs)
  else:
    # Unknown health -> reserve opportunistic budget
    reservedForFallback = min(minFallbackMs, failingFallbackMs)

  # Second default attempt if we still have budget after reservation
  let availableForSecond = max(remaining - reservedForFallback, 0)
  # Be more permissive: allow a shorter second attempt if we have at least 150ms
  if availableForSecond >= 150:
    let t2 = min(secondAttemptMs, availableForSecond)
    try:
      result = await httpSend(session, firstUri, processorRequest, firstId, t2)
      return result
    except CatchableError as e2:
      safeWarn "Default attempt #2 failed: " & e2.msg
  else:
    safeWarn "Skipping default attempt #2 to keep fallback budget: remaining=" & $remaining & "ms, reservedFallback=" & $reservedForFallback & "ms"

  # Compute remaining budget
  elapsed = (getTime() - wallStart).inMilliseconds.int
  remaining = max(totalBudgetMs - elapsed, 0)
  if remaining < 100:
    raise newException(CatchableError, "No time left for fallback")
  # Try fallback within remaining budget. Even if health is failing/unknown, do a short opportunistic attempt.
  healthOk = fbHealthOk
  var fbTimeout = remaining
  if healthOk and (not fbHealth.failing):
    # Healthy: allocate enough time based on minRT + margin, but not less than minFallbackMs
    fbTimeout = min(remaining, max(minFallbackMs, fbHealth.minResponseTime + safetyMargin))
  else:
    # Failing or unknown: still attempt briefly
    fbTimeout = min(remaining, max(min(minFallbackMs, failingFallbackMs), 150))
    if healthOk:
      safeWarn "Attempting fallback despite failing health with timeout=" & $fbTimeout & "ms"
    else:
      safeWarn "Attempting fallback with unknown health with timeout=" & $fbTimeout & "ms"
  try:
    result = await httpSend(session, fbUri, processorRequest, fbId, fbTimeout)
    return result
  except CatchableError as e2:
    safeWarn "Fallback processor failed: " & e2.msg
    raise newException(CatchableError, "All payment processors failed")
