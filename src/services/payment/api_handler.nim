import std/[json, os, strutils, times]
import chronos
import chronos/transports/stream
import ../../core/domain

proc isUuidV4(s: string): bool =
  # Basic UUID v4 pattern: 8-4-4-4-12 hex, version nibble '4' and variant starting with 8|9|a|b
  if s.len != 36: return false
  let parts = s.split('-')
  if parts.len != 5: return false
  if parts[0].len != 8 or parts[1].len != 4 or parts[2].len != 4 or parts[3].len != 4 or parts[4].len != 12: return false
  for ch in parts[0] & parts[1] & parts[2] & parts[3] & parts[4]:
    if not (ch in {'0'..'9'} or ch in {'a'..'f'} or ch in {'A'..'F'}): return false
  if parts[2][0] != '4': return false
  let v = parts[3][0]
  if not (v == '8' or v == '9' or v == 'a' or v == 'A' or v == 'b' or v == 'B'): return false
  true

proc parsePaymentRequest*(jsonStr: string): PaymentRequest =
  let parsed = parseJson(jsonStr)
  let cid = parsed["correlationId"].getStr()
  if not isUuidV4(cid):
    raise newException(CatchableError, "Invalid correlationId; must be UUID v4")
  result.correlationId = cid
  result.amount = parsed["amount"].getFloat()
  # Capture requestedAt if present; otherwise use server receipt time (now)
  if parsed.hasKey("requestedAt"):
    try:
      let dt = parsed["requestedAt"].getStr()
      let micros = (times.parseTime(dt, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", times.utc()).toUnixFloat() * 1_000_000).int64
      result.requestedAtMicros = micros
    except:
      result.requestedAtMicros = 0'i64
  else:
    # Convert DateTime to Time before toUnixFloat
    result.requestedAtMicros = (now().toTime().toUnixFloat() * 1_000_000).int64

proc send*(buf: seq[byte], payment: PaymentRequest): Future[bool] {.async, gcsafe.} =
  # Send a JSON request the worker understands: {"type":"payment","data":{...}}
  let workerSocket = getEnv("WORKER_SOCKET", "/tmp/worker.sock")
  let transport = await connect(initTAddress(workerSocket))

  # Build minimal payload including requestedAtMicros if available
  let payload = %*{
    "type": "payment",
    "data": {
      "correlationId": payment.correlationId,
      "amount": payment.amount,
      "requestedAtMicros": payment.requestedAtMicros
    }
  }

  discard await transport.write($payload)
  # Fire-and-forget: consider enqueued if write succeeds; worker handles ack internally.
  try:
    await transport.closeWait()
  except:
    discard
  return true
