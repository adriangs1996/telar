#include "render_work_census.h"
#include <errno.h>
#include <os/lock.h>
#include <time.h>

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static bool active;
static RenderWorkSnapshot counters;

static void record_locked(enum RenderWorkCounter counter, uint64_t amount) {
  if ((unsigned)counter >= render_work_count || amount > UINT64_MAX - counters.counts[counter]) {
    ++counters.errors;
    return;
  }

  counters.counts[counter] += amount;
}

int telar_render_work_begin(void) {
  os_unfair_lock_lock(&lock);
  if (active) {
    os_unfair_lock_unlock(&lock);
    return EBUSY;
  }

  counters = (RenderWorkSnapshot){.begin_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)};
  active = true;
  os_unfair_lock_unlock(&lock);
  return 0;
}

void telar_render_work_record(enum RenderWorkCounter counter, uint64_t amount) {
  os_unfair_lock_lock(&lock);
  if (active) {
    record_locked(counter, amount);
  }
  os_unfair_lock_unlock(&lock);
}

void telar_render_work_pair(enum RenderWorkCounter first, enum RenderWorkCounter second) {
  os_unfair_lock_lock(&lock);
  if (active) {
    record_locked(first, 1);
    record_locked(second, 1);
  }
  os_unfair_lock_unlock(&lock);
}

void telar_render_work_commit(unsigned sequence) {
  os_unfair_lock_lock(&lock);
  if (active) {
    if (sequence >= render_work_sequence_capacity || counters.counts[render_work_commits] == UINT64_MAX || counters.commits_by_sequence[sequence] == UINT64_MAX) {
      ++counters.errors;
    } else {
      ++counters.counts[render_work_commits];
      ++counters.commits_by_sequence[sequence];
    }
  }

  os_unfair_lock_unlock(&lock);
}

RenderWorkSnapshot telar_render_work_end(void) {
  os_unfair_lock_lock(&lock);
  if (active) {
    counters.end_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    counters.complete = true;
    active = false;
  } else {
    counters.complete = false;
    ++counters.errors;
  }

  const RenderWorkSnapshot result = counters;
  os_unfair_lock_unlock(&lock);
  return result;
}
