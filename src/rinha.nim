import std/[os, logging, strutils]
import chronos
import cligen
import servers/api_server
import servers/worker_server

# Global variables
var WORKER_SOCKET* {.global.}: string = getEnv("WORKER_SOCKET", "./worker.sock")

proc initTracing() =
  # Load environment variables (equivalent to dotenvy::dotenv())
  try:
    discard # Could load .env file if needed
  except:
    discard
  
  # Set up logging filter equivalent to EnvFilter::try_from_default_env()
  let logLevel = getEnv("RINHA_LOGLEVEL", "info").toLowerAscii()
  var level = lvlInfo
  case logLevel:
  of "debug": level = lvlDebug
  of "info": level = lvlInfo
  of "warn": level = lvlWarn
  of "error": level = lvlError
  else: level = lvlInfo
  
  # Configure logger with format
  let logger = newConsoleLogger(level,
    fmtStr = "$levelname $datetime $filename:$line [$thread] $msg",
    useStderr = true)
  addHandler(logger)

proc serve(mode: string) =
  let result = case mode:
  of "api":
    try:
      discard waitFor api_server.serve()
      0
    except CatchableError as e:
      error "API server error: ", e.msg
      1
  of "worker":
    try:
      waitFor worker_server.serve()
      0
    except CatchableError as e:
      error "Worker server error: ", e.msg
      1
  else:
    error "Invalid mode: ", mode
    echo "Valid modes: api, worker"
    1
  
  if result != 0:
    error "FATAL: Exiting"
    quit(result)

proc bindUnixSocket*(file: string): Future[StreamServer] {.async.} =
  try:
    removeFile(file)
  except OSError:
    discard
  
  let serverAddr = initTAddress(file)
  result = createStreamServer(serverAddr, {ReuseAddr})
  
  # Set permissions to 0o666 equivalent
  try:
    setFilePermissions(file, {fpUserRead, fpUserWrite, fpGroupRead, fpGroupWrite, fpOthersRead, fpOthersWrite})
  except OSError:
    discard

proc main(mode = "api") =
  ## Rinha 2025
  ## Args:
  ##   mode: The mode in which the binary will run [api, worker]
  
  initTracing()
  
  serve(mode)

when isMainModule:
  dispatch(main, help = {"mode": "The mode in which the binary will run [api, worker]"})
