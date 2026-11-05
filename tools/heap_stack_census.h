#pragma once
#include <stdbool.h>
#include <stdint.h>

enum { heap_stack_capacity = 8192, heap_stack_depth = 24, heap_stack_max_shift = 12 };
enum HeapAllocationApi { heap_malloc, heap_calloc, heap_realloc, heap_aligned, heap_posix_aligned, heap_api_count };

typedef struct {
  uint64_t ordinal, at_ns, thread_id, requested_bytes;
  uint64_t api, depth, frames[heap_stack_depth];
} HeapStackRecord;

typedef struct {
  uint64_t begin_ns, end_ns, successful_calls, null_returns, free_calls, requested_bytes;
  uint64_t api_calls[heap_api_count];
  uint64_t used, overflow, errors, sample_shift;
  bool complete, sampling;
  HeapStackRecord records[heap_stack_capacity];
} HeapStackSnapshot;

int telar_heap_stack_begin(unsigned sample_shift, bool sampling);
int telar_heap_stack_end(HeapStackSnapshot *result);
