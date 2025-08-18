import json, times

type
  Payment* = object
    amount*: uint64
    requested_at*: int64
    processor_id*: uint8

  ProcessorPaymentRequest* = object
    requested_at*: DateTime
    amount*: float32
    correlation_id*: string

  # Forward declaration to avoid circular dependency
  PaymentRequest* = object
    correlationId*: string
    amount*: float32
    requestedAtMicros*: int64

  WorkerRequestKind* = enum
    Summary, PaymentReq, PurgeDb, Unknown

  WorkerRequest* = object
    case kind*: WorkerRequestKind
    of Summary:
      query*: tuple[fromTime, toTime: int64]
    of PaymentReq:
      payment*: PaymentRequest
    of PurgeDb:
      discard
    of Unknown:
      discard

# Custom JSON converters for tuple
proc `%`*(t: tuple[fromTime, toTime: int64]): JsonNode =
  result = newJObject()
  result["fromTime"] = %t.fromTime
  result["toTime"] = %t.toTime

proc to*(json: JsonNode, T: typedesc[tuple[fromTime, toTime: int64]]): tuple[fromTime, toTime: int64] =
  result.fromTime = json["fromTime"].getInt()
  result.toTime = json["toTime"].getInt()

# Simplified serialization using JSON only
proc encode*[S](input: S, buf: var seq[uint8]): int =
  when S is tuple[fromTime, toTime: int64]:
    try:
      let jsonStr = $(%input)
      buf = cast[seq[uint8]](jsonStr)
      result = buf.len
    except:
      buf = @[]
      result = 0
  else:
    # Fallback no-op; most codepaths now send explicit JSON strings
    buf = @[]
    result = 0

# Decode buffer using JSON only
proc decode*(input: seq[uint8]): WorkerRequest =
  if input.len == 0:
    return WorkerRequest(kind: Unknown)

  try:
    let jsonStr = cast[string](input)
    let jsonObj = parseJson(jsonStr)

    # Handle API format: {"type": "get_summary"|"payment"|"purge", "data": {...}}
    if jsonObj.hasKey("type"):
      let requestType = jsonObj["type"].getStr()
      case requestType
      of "get_summary":
        let data = jsonObj["data"]
        let fromTime = data["fromTime"].getInt().int64
        let toTime = data["toTime"].getInt().int64
        return WorkerRequest(kind: Summary, query: (fromTime, toTime))
      of "payment":
        let data = jsonObj["data"]
        let correlationId = if data.hasKey("correlationId"): data["correlationId"].getStr() else: data.getOrDefault("paymentId").getStr()
        let amount = data["amount"].getFloat().float32
        let reqMicros = if data.hasKey("requestedAtMicros"): data["requestedAtMicros"].getInt().int64 else: 0'i64
        return WorkerRequest(kind: PaymentReq, payment: PaymentRequest(correlationId: correlationId, amount: amount, requestedAtMicros: reqMicros))
      of "purge":
        return WorkerRequest(kind: PurgeDb)
      else:
        return WorkerRequest(kind: Unknown)

    # Handle internal worker format: {"kind": "PaymentReq"|"Summary"|"PurgeDb", ...}
    elif jsonObj.hasKey("kind"):
      let kindStr = jsonObj["kind"].getStr()
      case kindStr
      of "PaymentReq":
        let paymentObj = jsonObj["payment"]
        let correlationId = paymentObj["correlationId"].getStr()
        let amount = paymentObj["amount"].getFloat().float32
        let reqMicros = if paymentObj.hasKey("requestedAtMicros"): paymentObj["requestedAtMicros"].getInt().int64 else: 0'i64
        return WorkerRequest(kind: PaymentReq, payment: PaymentRequest(correlationId: correlationId, amount: amount, requestedAtMicros: reqMicros))
      of "Summary":
        let query = jsonObj["query"]
        let fromTime = query["fromTime"].getInt().int64
        let toTime = query["toTime"].getInt().int64
        return WorkerRequest(kind: Summary, query: (fromTime, toTime))
      of "PurgeDb":
        return WorkerRequest(kind: PurgeDb)
      else:
        return WorkerRequest(kind: Unknown)
    else:
      return WorkerRequest(kind: Unknown)
  except:
    return WorkerRequest(kind: Unknown)

# Overload for byte arrays with JSON support only
proc decode*[D](input: openArray[uint8], T: typedesc[D]): D =
  let data = @input
  try:
    let jsonStr = cast[string](data)
    result = to(parseJson(jsonStr), D)
  except:
    # Return default value
    when D is WorkerRequest:
      result = WorkerRequest(kind: Unknown)
    else:
      # Try to construct default value
      result = default(D)
