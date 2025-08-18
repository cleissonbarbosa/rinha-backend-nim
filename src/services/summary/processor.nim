import std/[strformat, logging]
import chronos
import ../../infrastructure/database/store

proc buildPayload(defaultCount: uint64, defaultAmount: float64, fallbackCount: uint64, fallbackAmount: float64): string =
  # Proper JSON without escaping for nginx/proxy to forward as-is
  result = fmt"""{{"default":{{"totalRequests":{defaultCount},"totalAmount":{defaultAmount}}},"fallback":{{"totalRequests":{fallbackCount},"totalAmount":{fallbackAmount}}}}}"""

template safeDebug(msg: string) =
  try:
    debug msg
  except:
    discard

proc process*(transport: StreamTransport, store: Store, query: tuple[fromTime, toTime: int64], buf: var seq[byte]) {.async: (raises: [CatchableError]).} =
  await sleepAsync(2.milliseconds)
  
  let acc = await store.getPerProcessor(query)
  let defCount = acc[0].count
  let defAmount = acc[0].totalAmount.float64 / 100.0
  let fbCount = acc[1].count
  let fbAmount = acc[1].totalAmount.float64 / 100.0
  
  let payload = buildPayload(defCount, defAmount, fbCount, fbAmount)
  safeDebug "[worker.summary] payload: " & payload
  discard await transport.write(payload)
