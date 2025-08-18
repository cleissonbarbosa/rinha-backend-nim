import chronos
import chronos/streams
import ../data
import ../worker/worker_mod

proc purge*() {.async.} =
  let transport = await connect(initTAddress(WORKER_SOCKET))
  
  var buf = newSeq[byte](32)
  let n = encode(WorkerRequest(kind: PurgeDb), buf)
  
  await transport.write(addr buf[0], n)
  await transport.closeWait()
