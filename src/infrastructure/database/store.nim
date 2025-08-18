import chronos
import std/[strutils, sequtils, times]
import ../../core/domain

type
  Store* = ref object
    payments: seq[Payment]
    lock: AsyncLock

proc newStore*(): Store =
  Store(
    payments: newSeqOfCap[Payment](20_000),
    lock: newAsyncLock()
  )

# Binary search implementation for efficient range queries (O(log n))
proc binarySearchByTime(payments: seq[Payment], target: int64): int =
  var left = 0
  var right = payments.len - 1
  
  while left <= right:
    let mid = left + (right - left) div 2
    
    if payments[mid].requested_at == target:
      return mid
    elif payments[mid].requested_at < target:
      left = mid + 1
    else:
      right = mid - 1
  
  return left  # Return insertion point

proc insert*(store: Store, payment: Payment) {.async: (raises: [CatchableError, CancelledError]), gcsafe.} =
  await store.lock.acquire()
  try:
    # Just append; avoid O(n log n) sort at every insert which caused stalls/timeouts under load
    store.payments.add(payment)
  finally:
    try:
      store.lock.release()
    except:
      discard

proc get*(store: Store, query: tuple[fromTime, toTime: int64]): Future[tuple[count: int, totalAmount: uint64]] {.async: (raises: [AsyncLockError, CancelledError]), gcsafe.} =
  # Backward-compatible aggregate across all processors
  await store.lock.acquire()
  try:
    var count = 0
    var totalAmount: uint64 = 0
    for p in store.payments:
      if p.requested_at >= query.fromTime and p.requested_at <= query.toTime:
        inc count
        let newAmount = totalAmount + p.amount
        if newAmount < totalAmount: break
        totalAmount = newAmount
    result = (count, totalAmount)
  finally:
    try:
      store.lock.release()
    except:
      discard

# New: per-processor aggregation for accurate default/fallback reporting
proc getPerProcessor*(store: Store, query: tuple[fromTime, toTime: int64]): Future[array[2, tuple[count: uint64, totalAmount: uint64]]] {.async, gcsafe.} =
  var acc: array[2, tuple[count: uint64, totalAmount: uint64]]
  
  await store.lock.acquire()
  try:
    for p in store.payments:
      if p.requested_at >= query.fromTime and p.requested_at <= query.toTime:
        let idx = (if p.processor_id == 1'u8: 0 else: 1)
        acc[idx].count.inc
        let newAmount = acc[idx].totalAmount + p.amount
        if newAmount >= acc[idx].totalAmount:
          acc[idx].totalAmount = newAmount
  finally:
    try:
      store.lock.release()
    except:
      discard
  return acc

proc purge*(store: Store) {.async: (raises: [CatchableError, CancelledError]), gcsafe.} =
  await store.lock.acquire()
  try:
    store.payments.setLen(0)
  finally:
    try:
      store.lock.release()
    except:
      discard
