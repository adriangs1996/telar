#include "render_work_census.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

enum Work {
  workers = 8,
  iterations = 10000,
  bulk_amount = 7
};

static void *record_worker(void *unused) {
  (void)unused;
  for (unsigned index = 0; index < iterations; ++index) {
    telar_render_work_pair(render_work_drawable_completions, render_work_drawables);
    telar_render_work_record(render_work_optical_requests, bulk_amount);
  }

  return NULL;
}

int main(void) {
  telar_render_work_record(render_work_commits, 1);
  assert(telar_render_work_begin() == 0);
  assert(telar_render_work_begin() == EBUSY);
  pthread_t threads[workers];
  for (unsigned index = 0; index < workers; ++index) {
    assert(pthread_create(&threads[index], NULL, record_worker, NULL) == 0);
  }

  for (unsigned index = 0; index < workers; ++index) {
    assert(pthread_join(threads[index], NULL) == 0);
  }

  const RenderWorkSnapshot first = telar_render_work_end();
  assert(first.complete && first.errors == 0 && first.end_ns >= first.begin_ns);
  assert(first.counts[render_work_commits] == 0);
  assert(first.counts[render_work_drawable_completions] == workers * iterations);
  assert(first.counts[render_work_drawables] == workers * iterations);
  assert(first.counts[render_work_optical_requests] == workers * iterations * bulk_amount);
  telar_render_work_record(render_work_commits, 1);
  assert(!telar_render_work_end().complete);

  assert(telar_render_work_begin() == 0);
  telar_render_work_record(render_work_commits, UINT64_MAX);
  telar_render_work_record(render_work_commits, 1);
  telar_render_work_record(render_work_count, 1);
  const RenderWorkSnapshot invalid = telar_render_work_end();
  assert(invalid.complete && invalid.errors == 2);
  assert(invalid.counts[render_work_commits] == UINT64_MAX);
  assert(invalid.counts[render_work_optical_requests] == 0);

  assert(telar_render_work_begin() == 0);
  for (unsigned index = 0; index < workers; ++index) {
    assert(pthread_create(&threads[index], NULL, record_worker, NULL) == 0);
  }

  const RenderWorkSnapshot stopped = telar_render_work_end();
  for (unsigned index = 0; index < workers; ++index) {
    assert(pthread_join(threads[index], NULL) == 0);
  }

  const RenderWorkSnapshot after_stop = telar_render_work_end();
  assert(stopped.complete && stopped.errors == 0 && !after_stop.complete);
  assert(stopped.counts[render_work_drawable_completions] == stopped.counts[render_work_drawables]);
  assert(stopped.counts[render_work_drawables] <= workers * iterations);
  for (unsigned index = 0; index < render_work_count; ++index) {
    assert(stopped.counts[index] == after_stop.counts[index]);
  }

  puts("Concurrent counts/stop, paired totals, inactive boundaries, restart, overflow and invalid counter controls pass.");
  return 0;
}
