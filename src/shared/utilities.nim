import chronos
import chronos/transports/stream
import std/os

proc purge*() {.async, gcsafe.} =
  # Resolve worker socket at runtime (env from docker-compose), not at compile time
  let workerSocket = getEnv("WORKER_SOCKET", "/tmp/worker.sock")
  let transport = await connect(initTAddress(workerSocket))
  # Send a simple purge request JSON that worker.decode understands
  discard await transport.write("{\"type\":\"purge\"}")
  # No response is expected; close to signal EOF
  await transport.closeWait()
