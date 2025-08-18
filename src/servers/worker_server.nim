import std/[os, strutils, logging]
import chronos
import chronos/asyncsync
import chronos/transports/stream
import chronos/apps/http/httpclient as httpc
import ../services/payment/processor
import ../services/payment/client
import ../services/summary/processor as summary_processor
import ../core/domain
import ../infrastructure/database/store

let HTTP_WORKERS: int =
  try:
    parseInt(getEnv("HTTP_WORKERS", "32"))
  except:
    32

type
  Sender = AsyncQueue[PaymentRequest]
  Receiver = AsyncQueue[PaymentRequest]

# Forward declarations
proc purgeDb(store: Store) {.async, gcsafe.}
proc handleUds(tx: Sender, transport: StreamTransport, store: Store) {.async, gcsafe.}
proc startHttpWorker(store: Store, tx: Sender, rx: Receiver, paymentClient: PPClient, session: httpc.HttpSessionRef) {.async, gcsafe.}
proc startHttpWorkers(store: Store): Sender {.gcsafe, raises: [].}
proc udsListen(tx: Sender, store: Store, workerSocket: string): Future[void] {.async, gcsafe.}

# Safe logging helpers to avoid exceptions
template safeDebug(msg: string) =
  try:
    debug msg
  except:
    discard

proc serve*() {.async, gcsafe.} =
  try:
    # info "starting worker"
    let workerSocket = getEnv("WORKER_SOCKET", "/tmp/worker.sock")
    let store = store.newStore()
    let reqTx = startHttpWorkers(store)
    await udsListen(reqTx, store, workerSocket)
  except CatchableError as e:
    # error "Failed to serve worker: ", e.msg
    discard

proc startHttpWorkers(store: Store): Sender {.gcsafe, raises: [].} =
  let queue = newAsyncQueue[PaymentRequest]()
  let paymentClient = client.newPPClient()

  proc worker() {.async, gcsafe.} =
    let session = httpc.HttpSessionRef.new()
    try:
      await startHttpWorker(store, queue, queue, paymentClient, session)
    finally:
      try:
        await noCancel(session.closeWait())
      except:
        discard

  for i in 0..<HTTP_WORKERS:
    asyncSpawn worker()

  return queue

proc startHttpWorker(store: Store, tx: Sender, rx: Receiver, paymentClient: PPClient, session: httpc.HttpSessionRef) {.async, gcsafe.} =
  while true:
    let req = await rx.popFirst()
    try:
      await processor.process(store, paymentClient, session, req)
    except CatchableError:
      # Re-enqueue once to smooth transient PP timeouts; then drop
      try:
        await tx.addLast(req)
      except CatchableError:
        discard

proc udsListen(tx: Sender, store: Store, workerSocket: string) {.async, gcsafe.} =
  let serverAddr = initTAddress(workerSocket)
  
  # info "starting worker server on socket: ", workerSocket
  
  # Remove existing socket if it exists
  if fileExists(workerSocket):
    removeFile(workerSocket)
  
  proc processClient(server: StreamServer, transport: StreamTransport) {.async, gcsafe.} =
    try:
      await handleUds(tx, transport, store)
    except CatchableError as e:
      # error "Error in processClient: ", e.msg
      discard
    finally:
      await transport.closeWait()
  
  let server = createStreamServer(serverAddr, processClient, {ReuseAddr})
  server.start()
  # Set socket permissions to be accessible by api containers
  try:
    setFilePermissions(workerSocket, {fpUserRead, fpUserWrite, fpGroupRead, fpGroupWrite, fpOthersRead, fpOthersWrite})
  except OSError:
    discard
  # info "worker server started successfully"
  
  while server.status != ServerStatus.Stopped:
    await sleepAsync(1000)

proc handleUds(tx: Sender, transport: StreamTransport, store: Store) {.async, gcsafe.} =
  # Read full JSON request from API; the API writes a single JSON object and then waits for response.
  var buf = newSeq[byte](512)
  var total = 0
  while true:
    if total >= buf.len:
      buf.setLen(buf.len * 2)
    let n = await transport.readOnce(addr buf[total], buf.len - total)
    if n <= 0:
      break
    total += n
    if total > 0 and buf[total-1] == ord('}'):
      break
  
  let req = decode(buf[0..<total])
  
  safeDebug "Received request kind: " & $req.kind
  
  case req.kind:
  of WorkerRequestKind.Summary:
    safeDebug "Processing Summary request"
    await summary_processor.process(transport, store, req.query, buf)
  of WorkerRequestKind.PaymentReq:
    safeDebug "Processing Payment request - correlationId: " & req.payment.correlationId
    # Synchronous processing: respond to API only after processor acceptance
    let paymentClient = client.newPPClient()
    let session = httpc.HttpSessionRef.new()
    try:
      await processor.process(store, paymentClient, session, req.payment)
      discard await transport.write("OK")
    except CatchableError:
      discard await transport.write("ERR")
    finally:
      try:
        await noCancel(session.closeWait())
      except:
        discard
  of WorkerRequestKind.PurgeDb:
    safeDebug "Processing PurgeDb request"
    await purgeDb(store)
    # Send a tiny ACK so the client can consider the operation complete
    try:
      discard await transport.write("OK")
    except:
      discard
  of WorkerRequestKind.Unknown:
    safeDebug "Received Unknown request - ignoring"

proc purgeDb(store: Store) {.async, gcsafe.} =
  await store.purge()
