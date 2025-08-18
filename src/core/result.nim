# Result type
type
  Result*[T, E] = object
    case isOk*: bool
    of true:
      value*: T
    of false:
      error*: E

proc ok*[T](value: T): Result[T, ref CatchableError] =
  Result[T, ref CatchableError](isOk: true, value: value)

proc ok*(): Result[void, ref CatchableError] =
  Result[void, ref CatchableError](isOk: true)

proc err*[T, E](error: E): Result[T, E] =
  Result[T, E](isOk: false, error: error)

proc get*[T, E](r: Result[T, E]): T =
  if r.isOk:
    r.value
  else:
    raise r.error

proc isOk*[T, E](r: Result[T, E]): bool =
  r.isOk

proc isErr*[T, E](r: Result[T, E]): bool =
  not r.isOk
