#include "macos_thread_cpu.h"
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

enum Work {
  nanoseconds_per_millisecond = 1000000,
  busy_milliseconds = 250,
  main_milliseconds = 80,
  short_milliseconds = 10,
  short_threads = 8,
  settle_milliseconds = 400
};

enum ExitCode {
  usage_error = 2,
  worker_error = 3,
  capture_error = 4,
  churn_error = 5,
  completion_error = 6
};

static atomic_uint ready;
static atomic_bool start;
static atomic_bool stop;

typedef struct {
  bool busy;
  uint64_t id;
  uint64_t measured_ns;
} Worker;

static void sleep_milliseconds(unsigned milliseconds) {
  const struct timespec delay = {.tv_sec = 0, .tv_nsec = (long)milliseconds * nanoseconds_per_millisecond};
  nanosleep(&delay, NULL);
}

static uint64_t burn(unsigned milliseconds) {
  const uint64_t begin = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
  uint64_t now = begin;
  while (now - begin < (uint64_t)milliseconds * nanoseconds_per_millisecond) {
    now = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
  }
  return now - begin;
}

static void *worker(void *context) {
  Worker *state = context;
  pthread_setname_np(state->busy ? "control-busy" : "control-sleep");
  pthread_threadid_np(NULL, &state->id);
  atomic_fetch_add(&ready, 1);
  while (!atomic_load(&start)) {
    sleep_milliseconds(1);
  }
  if (state->busy) {
    state->measured_ns = burn(busy_milliseconds);
  }
  while (!atomic_load(&stop)) {
    sleep_milliseconds(1);
  }
  return NULL;
}

static void *short_worker(void *context) {
  Worker *state = context;
  pthread_setname_np("control-short");
  pthread_threadid_np(NULL, &state->id);
  state->measured_ns = burn(short_milliseconds);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    return usage_error;
  }
  pthread_setname_np("control-main");
  Worker busy = {.busy = true}, sleeping = {0}, short_lived[short_threads] = {0};
  pthread_t busy_thread, sleeping_thread;
  if (pthread_create(&busy_thread, NULL, worker, &busy) != 0 || pthread_create(&sleeping_thread, NULL, worker, &sleeping) != 0) {
    return worker_error;
  }
  while (atomic_load(&ready) != 2) {
    sleep_milliseconds(1);
  }
  if (telar_thread_cpu_begin(argv[1]) != 0) {
    return capture_error;
  }
  atomic_store(&start, true);
  const uint64_t main_ns = burn(main_milliseconds);
  for (unsigned index = 0; index < short_threads; ++index) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, short_worker, &short_lived[index]) != 0 || pthread_join(thread, NULL) != 0) {
      return churn_error;
    }
  }
  sleep_milliseconds(settle_milliseconds);
  const int result = telar_thread_cpu_end();
  atomic_store(&stop, true);
  pthread_join(busy_thread, NULL);
  pthread_join(sleeping_thread, NULL);
  printf("{\"observer_result\":%d,\"main_burn_ns\":%" PRIu64 ",\"busy_id\":%" PRIu64
         ",\"busy_burn_ns\":%" PRIu64 ",\"sleep_id\":%" PRIu64 ",\"short\":[",
         result, main_ns, busy.id, busy.measured_ns, sleeping.id);
  for (unsigned index = 0; index < short_threads; ++index) {
    printf("%s{\"id\":%" PRIu64 ",\"burn_ns\":%" PRIu64 "}", index == 0 ? "" : ",", short_lived[index].id, short_lived[index].measured_ns);
  }
  puts("]}");
  return result == 0 ? 0 : completion_error;
}
