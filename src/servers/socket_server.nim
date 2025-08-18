import std/[os, strutils, logging, times, json]
import chronos
import chronos/streams
import chronos/apps/http/httpclient as httpc
import ../data, ../db, ../rinha
import payment, pp_client, summary_handler

const HTTP_WORKERS = 2

type
  Sender = AsyncChannel[PaymentRequest]
  Receiver = AsyncChannel[PaymentRequest]

proc serve*(): Future[Result[void, ref CatchableError]] {.async.} =
  try:
    info "starting worker"
    
    let store = newStore()
    let reqTx = startHttpWorkers(store)
    
    await udsListen(reqTx, store)
    
    return ok()
  except Exception as e:
    error "Worker serve error: ", e.msg
    return err(e)

proc startHttpWorkers(store: Store): Sender =
  let (tx, rx) = newAsyncChannel[PaymentRequest]()
  
  info "starting payment_req_consumer"
  let client = httpc.newHttpClient()
  
  for i in 0..<HTTP_WORKERS:
    let worker = startHttpWorker(store, tx, rx, client)
    asyncSpawn worker
  
  return tx

proc startHttpWorker[T](store: Store, tx: Sender, rx: Receiver, http: T) {.async.} =
  let ppClient = newPPClient()
  while true:
    let req = await rx.recv()
    try:
  await payment.process(store, ppClient, http, req)
    except CatchableError as e:
      debug "pp_client_err - retrying: ", e.msg
      await tx.send(req)

proc udsListen(tx: Sender, store: Store) {.async.} =
  let workerSocket = getEnv("WORKER_SOCKET", "/tmp/worker.sock")
  let listener = await bindUnixSocket(workerSocket)
  
  info "listening on ", workerSocket
  
  while true:
    let (transport, address) = await listener.accept()
    debug "accepted unix socket connection"
    
    asyncSpawn handleUds(tx, transport, store)

proc handleUds(tx: Sender, transport: StreamTransport, store: Store) {.async.} =
  try:
    let now = Moment.now()
    # Read the full JSON message from API (single object). The API writes once; we break on '}' or EOF.
    var buf = newSeq[byte](512)
    var total = 0
    while true:
      if total >= buf.len:
        buf.setLen(buf.len * 2)
      let n = await transport.readOnce(addr buf[total], buf.len - total)
      if n <= 0:
        break
      total += n
      if total > 0 and buf[total - 1] == ord('}'):
        break
    
    let req = decode(buf[0..<total])  # Use the overloaded decode
    
    case req.kind:
    of Summary:
      debug "Received request kind: Summary"
      await summary_handler.process(transport, store, req.query, buf)
    of PaymentReq:
      debug "Received request kind: PaymentReq"
      debug "Processing Payment request - correlationId: ", req.payment.correlationId
      await tx.send(req.payment)
    of PurgeDb:
      debug "Received request kind: PurgeDb"
      await store.purge()
    of Unknown:
      debug "Received request kind: Unknown - ignoring"
    
    let elapsed = Moment.now() - now
    debug "uds.handle took: ", elapsed.microseconds, " μs"
    
  except Exception as e:
    error "handle_uds error: ", e.msg
  finally:
    await transport.closeWait()
