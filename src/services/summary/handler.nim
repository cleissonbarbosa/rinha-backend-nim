import std/[logging, strformat]
import chronos
import chronos/streams
import ../../infrastructure/database/store

proc process*(transport: StreamTransport, store: Store, query: tuple[fromTime, toTime: int64], buf: var seq[byte]) {.async.} =
  debug "handling get_summary"
  
  # Add 2ms delay
  await sleepAsync(2.milliseconds)
  
  # Prefer per-processor aggregation; fall back to combined if needed
  let per = await store.getPerProcessor(query)
  let defaultCount = per[0].count
  let defaultAmount = (per[0].totalAmount.float32 / 100.0)
  let fallbackCount = per[1].count
  let fallbackAmount = (per[1].totalAmount.float32 / 100.0)
  let payload = buildPayload(defaultCount, defaultAmount, fallbackCount, fallbackAmount)
  debug "summary payload: ", payload
  
  # Write the response payload to the transport that the API is reading from
  # NOTE: write the string directly; casting string -> seq[byte] is unsafe and produced empty payloads
  # Write payload and close to signal EOF so API can read full body reliably
  await transport.write(payload)
  try:
    await transport.closeWait()
  except:
    discard

proc buildPayload(defaultCount: uint64, defaultAmount: float32, fallbackCount: uint64, fallbackAmount: float32): string =
  fmt"""{"default":{"totalRequests":{defaultCount},"totalAmount":{defaultAmount}},"fallback":{"totalRequests":{fallbackCount},"totalAmount":{fallbackAmount}}}"""
