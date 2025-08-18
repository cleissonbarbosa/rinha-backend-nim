import asyncdispatch, asyncnet, logging, json, sequtils
import ../data
import ../db
import payment, summary_handler

const HTTP_WORKERS = 2
const BUFFER_SIZE = 128

type
  WorkerRequestKind* = enum
    Summary, Payment, PurgeDb
    
  WorkerRequest* = object
    case kind*: WorkerRequestKind
    of Summary:
      summaryQuery*: tuple[fromTime, toTime: int64]
    of Payment:
      paymentReq*: JsonNode
    of PurgeDb:
      discard

var requestChannel: Channel[JsonNode]
var store: Store

proc serve*(): Future[void] {.async.} =
  info("starting worker")
  
  store = newStore()
  requestChannel.open()
  
  # Start HTTP workers using async tasks instead of deprecated threadpool
  for i in 0..<HTTP_WORKERS:
    asyncCheck httpWorker()
  
  # Start UDS listener
  await udsListen()

proc httpWorker() {.async.} =
  while true:
    await sleepAsync(10) # Small delay to prevent busy waiting
    # Note: For a complete implementation, we need proper channel implementation
    # This is simplified for demonstration

proc udsListen(): Future[void] {.async.} =
  const WORKER_SOCKET = "./worker.sock"
  
  var server = newAsyncSocket()
  server.bindUnix(WORKER_SOCKET)
  server.listen()
  
  info("listening on ", WORKER_SOCKET)
  
  while true:
    let client = await server.accept()
    asyncCheck handleUds(client)

proc handleUds(client: AsyncSocket) {.async.} =
  try:
    var buffer = newSeq[byte](BUFFER_SIZE)
    let bytesRead = await client.recv(addr buffer[0], BUFFER_SIZE)
    
    if bytesRead > 0:
      let req = decode(buffer[0..<bytesRead], WorkerRequest)
      
      case req.kind:
      of Summary:
        await summary_handler.process(client, store, req.summaryQuery, buffer)
      of Payment:
        # Process payment request
        discard
      of PurgeDb:
        await purgeDb()
  except Exception as e:
    warn("Error handling UDS request: ", e.msg)
  finally:
    client.close()

proc purgeDb(): Future[void] {.async.} =
  store.purge()
  info("db purged")
