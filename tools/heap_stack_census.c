// Darwin-only diagnostic. Counts API results, not live memory or allocation CPU.
#include "heap_stack_census.h"
#include <errno.h>
#include <execinfo.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static atomic_bool active;
static atomic_int owner;
static _Thread_local bool observing;
static HeapStackSnapshot snapshot;

int telar_heap_stack_begin(unsigned sample_shift, bool sampling) {
  if (sample_shift > heap_stack_max_shift || observing) {
    return EINVAL;
  }

  observing = true;
  os_unfair_lock_lock(&lock);
  if (atomic_load_explicit(&active, memory_order_relaxed)) {
    os_unfair_lock_unlock(&lock);
    observing = false;
    return EBUSY;
  }

  void *warmup[heap_stack_depth];
  backtrace(warmup, heap_stack_depth);
  memset(&snapshot, 0, sizeof(snapshot));
  snapshot.sample_shift = sample_shift;
  snapshot.sampling = sampling;
  atomic_store_explicit(&owner, getpid(), memory_order_relaxed);
  snapshot.begin_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  atomic_store_explicit(&active, true, memory_order_release);
  os_unfair_lock_unlock(&lock);
  observing = false;
  return 0;
}

int telar_heap_stack_end(HeapStackSnapshot *result) {
  if (!result || observing || getpid() != atomic_load_explicit(&owner, memory_order_relaxed)) {
    return EINVAL;
  }

  observing = true;
  os_unfair_lock_lock(&lock);
  if (!atomic_load_explicit(&active, memory_order_relaxed)) {
    os_unfair_lock_unlock(&lock);
    observing = false;
    return EINVAL;
  }

  atomic_store_explicit(&active, false, memory_order_release);
  snapshot.end_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  snapshot.complete = true;
  memcpy(result, &snapshot, sizeof(snapshot));
  os_unfair_lock_unlock(&lock);
  observing = false;
  return 0;
}

static uint64_t mix(uint64_t value) {
  value = (value ^ (value >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
  value = (value ^ (value >> 27)) * UINT64_C(0x94d049bb133111eb);
  return value ^ (value >> 31);
}

static void observe(void *pointer, size_t bytes, enum HeapAllocationApi api) {
  if (observing || !atomic_load_explicit(&active, memory_order_acquire) || getpid() != atomic_load_explicit(&owner, memory_order_relaxed)) {
    return;
  }

  const int saved_errno = errno;
  observing = true;
  os_unfair_lock_lock(&lock);
  if (!atomic_load_explicit(&active, memory_order_relaxed)) {
    goto finish;
  }

  if (!pointer) {
    ++snapshot.null_returns;
    goto finish;
  }

  ++snapshot.successful_calls;
  ++snapshot.api_calls[api];
  if (bytes > UINT64_MAX - snapshot.requested_bytes) {
    ++snapshot.errors;
    goto finish;
  }

  snapshot.requested_bytes += bytes;
  const uint64_t ordinal = snapshot.successful_calls;
  const uint64_t mask = (UINT64_C(1) << snapshot.sample_shift) - 1;
  if (!snapshot.sampling || (mix(ordinal) & mask)) {
    goto finish;
  }

  if (snapshot.used == heap_stack_capacity) {
    ++snapshot.overflow;
    goto finish;
  }

  HeapStackRecord *record = &snapshot.records[snapshot.used++];
  record->ordinal = ordinal;
  record->at_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  record->requested_bytes = bytes;
  record->api = api;
  if (pthread_threadid_np(NULL, &record->thread_id) != 0) {
    ++snapshot.errors;
  }

  void *frames[heap_stack_depth];
  const int depth = backtrace(frames, heap_stack_depth);
  if (depth <= 0) {
    ++snapshot.errors;
  } else {
    record->depth = (uint64_t)depth;
    for (int index = 0; index < depth; ++index) {
      record->frames[index] = (uintptr_t)frames[index];
    }
  }

finish:
  os_unfair_lock_unlock(&lock);
  observing = false;
  errno = saved_errno;
}

static void *count_malloc(size_t bytes) {
  void *pointer = malloc(bytes);
  observe(pointer, bytes, heap_malloc);
  return pointer;
}

static void *count_calloc(size_t count, size_t bytes) {
  void *pointer = calloc(count, bytes);
  observe(pointer, count * bytes, heap_calloc);
  return pointer;
}

static void *count_realloc(void *previous, size_t bytes) {
  void *pointer = realloc(previous, bytes);
  observe(pointer, bytes, heap_realloc);
  return pointer;
}

static void count_free(void *pointer) {
  if (pointer && !observing && atomic_load_explicit(&active, memory_order_acquire) && getpid() == atomic_load_explicit(&owner, memory_order_relaxed)) {
    const int saved_errno = errno;
    os_unfair_lock_lock(&lock);
    if (atomic_load_explicit(&active, memory_order_relaxed)) {
      ++snapshot.free_calls;
    }
    os_unfair_lock_unlock(&lock);
    errno = saved_errno;
  }
  free(pointer);
}

static void *count_aligned(size_t alignment, size_t bytes) {
  void *pointer = aligned_alloc(alignment, bytes);
  observe(pointer, bytes, heap_aligned);
  return pointer;
}

static int count_posix_aligned(void **pointer, size_t alignment, size_t bytes) {
  const int result = posix_memalign(pointer, alignment, bytes);
  observe(result == 0 ? *pointer : NULL, bytes, heap_posix_aligned);
  return result;
}

#ifndef TELAR_HEAP_STACK_DIRECT_CONTROL
#define INTERPOSE(replacement, original) \
  __attribute__((used, section("__DATA,__interpose"))) \
  static const struct { const void *replacement; const void *original; } \
  hook_##original = {(const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&original}

INTERPOSE(count_malloc, malloc);
INTERPOSE(count_calloc, calloc);
INTERPOSE(count_realloc, realloc);
INTERPOSE(count_free, free);
INTERPOSE(count_aligned, aligned_alloc);
INTERPOSE(count_posix_aligned, posix_memalign);
#endif
