import chronos
import std/logging
import ../../core/domain
import ../../infrastructure/database/store
import chronos/apps/http/httpclient as httpc
import client

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

proc process*(store: Store, client: PPClient, session: httpc.HttpSessionRef, payment: PaymentRequest) {.async: (raises: [CatchableError]), gcsafe.} =
  try:
    safeDebug "Processing payment - correlationId: " & payment.correlationId & ", amount: " & $payment.amount
    let processedPayment = await client.send(session, payment)
    safeDebug "Payment processed, inserting to store"
    await store.insert(processedPayment)
    safeDebug "Payment inserted successfully"
  except CatchableError as e:
    safeWarn "Payment processing failed: " & e.msg
    raise newException(CatchableError, "Payment processing failed")
