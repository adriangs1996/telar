#include "render_work_census.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

enum { worker_count = 4, iterations = 10000, first_sequence = 21, last_sequence = 120 };

static void *record_worker(void *unused) {
  (void)unused;
  for (unsigned index = 0; index < iterations; ++index) {
    telar_render_work_commit(first_sequence + index % (last_sequence - first_sequence + 1));
  }

  return NULL;
}

static void verify_partition(const RenderWorkSnapshot *snapshot) {
  uint64_t total = 0;
  for (unsigned index = 0; index < render_work_sequence_capacity; ++index) {
    total += snapshot->commits_by_sequence[index];
  }

  assert(total == snapshot->counts[render_work_commits]);
}

int main(void) {
  telar_render_work_commit(0);
  assert(telar_render_work_begin() == 0);
  pthread_t threads[worker_count];
  for (unsigned index = 0; index < worker_count; ++index) {
    assert(pthread_create(&threads[index], NULL, record_worker, NULL) == 0);
  }

  for (unsigned index = 0; index < worker_count; ++index) {
    assert(pthread_join(threads[index], NULL) == 0);
  }

  const RenderWorkSnapshot complete = telar_render_work_end();
  assert(complete.complete && complete.errors == 0);
  verify_partition(&complete);
  assert(complete.counts[render_work_commits] == worker_count * iterations);
  assert(complete.commits_by_sequence[0] == 0);
  for (unsigned sequence = first_sequence; sequence <= last_sequence; ++sequence) {
    assert(complete.commits_by_sequence[sequence] == worker_count * iterations / (last_sequence - first_sequence + 1));
  }

  telar_render_work_commit(first_sequence);
  assert(!telar_render_work_end().complete);
  assert(telar_render_work_begin() == 0);
  telar_render_work_commit(render_work_sequence_capacity);
  const RenderWorkSnapshot invalid = telar_render_work_end();
  assert(invalid.errors == 1 && invalid.counts[render_work_commits] == 0);
  verify_partition(&invalid);

  assert(telar_render_work_begin() == 0);
  telar_render_work_record(render_work_commits, UINT64_MAX);
  telar_render_work_commit(first_sequence);
  const RenderWorkSnapshot overflow = telar_render_work_end();
  assert(overflow.errors == 1 && overflow.counts[render_work_commits] == UINT64_MAX);
  assert(overflow.commits_by_sequence[first_sequence] == 0);

  assert(telar_render_work_begin() == 0);
  for (unsigned index = 0; index < worker_count; ++index) {
    assert(pthread_create(&threads[index], NULL, record_worker, NULL) == 0);
  }

  const RenderWorkSnapshot stopped = telar_render_work_end();
  for (unsigned index = 0; index < worker_count; ++index) {
    assert(pthread_join(threads[index], NULL) == 0);
  }

  const RenderWorkSnapshot after = telar_render_work_end();
  assert(stopped.complete && stopped.errors == 0 && !after.complete);
  verify_partition(&stopped);
  verify_partition(&after);
  for (unsigned sequence = 0; sequence < render_work_sequence_capacity; ++sequence) {
    assert(stopped.commits_by_sequence[sequence] == after.commits_by_sequence[sequence]);
  }

  puts("Concurrent sequence partition, stop, restart, inactive, invalid index and overflow controls pass.");
}
