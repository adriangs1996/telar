#include "macos_thread_cpu.h"
#include <errno.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

enum Limits {
  maximum_threads = 1024,
  microseconds_per_second = 1000000,
  sample_period_ns = 100000000,
  hexadecimal_width = 2
};

typedef struct {
  uint64_t id;
  uint64_t user_us;
  uint64_t system_us;
  char name[MAXTHREADNAMESIZE];
  kern_return_t identifier_result;
  kern_return_t basic_result;
  kern_return_t name_result;
} ThreadCpu;

static FILE *output;
static pthread_t observer;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static bool stopping;
static int observer_error;
static unsigned sequence;

static uint64_t process_microseconds(struct timeval value) {
  return (uint64_t)value.tv_sec * microseconds_per_second + (uint64_t)value.tv_usec;
}

static uint64_t thread_microseconds(time_value_t value) {
  return (uint64_t)value.seconds * microseconds_per_second + (uint64_t)value.microseconds;
}

static ThreadCpu read_thread(thread_t thread) {
  ThreadCpu result = {0};
  thread_identifier_info_data_t identifier = {0};
  mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
  result.identifier_result = thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&identifier, &count);
  result.id = identifier.thread_id;

  thread_basic_info_data_t basic = {0};
  count = THREAD_BASIC_INFO_COUNT;
  result.basic_result = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&basic, &count);
  result.user_us = thread_microseconds(basic.user_time);
  result.system_us = thread_microseconds(basic.system_time);

  thread_extended_info_data_t extended = {0};
  count = THREAD_EXTENDED_INFO_COUNT;
  result.name_result = thread_info(thread, THREAD_EXTENDED_INFO, (thread_info_t)&extended, &count);
  memcpy(result.name, extended.pth_name, sizeof(result.name));
  result.name[sizeof(result.name) - 1] = '\0';
  return result;
}

static int snapshot(const char *kind) {
  ThreadCpu rows[maximum_threads];
  struct rusage before = {0}, after = {0};
  const uint64_t before_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  if (getrusage(RUSAGE_SELF, &before) != 0) {
    return errno;
  }

  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  const kern_return_t enumeration = task_threads(mach_task_self(), &threads, &count);
  const unsigned retained = count < maximum_threads ? count : maximum_threads;
  for (unsigned index = 0; index < count; ++index) {
    if (index < retained) {
      rows[index] = read_thread(threads[index]);
    }
    mach_port_deallocate(mach_task_self(), threads[index]);
  }
  if (threads != NULL) {
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(*threads));
  }

  if (getrusage(RUSAGE_SELF, &after) != 0) {
    return errno;
  }
  const uint64_t after_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  uint64_t sampler_id = 0;
  pthread_threadid_np(NULL, &sampler_id);
  fprintf(output, "{\"type\":\"snapshot\",\"kind\":\"%s\",\"sequence\":%u,\"sampler_id\":%" PRIu64
          ",\"before_ns\":%" PRIu64 ",\"after_ns\":%" PRIu64
          ",\"process_before_us\":[%" PRIu64 ",%" PRIu64 "],\"process_after_us\":[%" PRIu64 ",%" PRIu64
          "],\"enumeration_result\":%d,\"enumerated\":%u,\"threads\":[",
          kind, sequence++, sampler_id, before_ns, after_ns,
          process_microseconds(before.ru_utime), process_microseconds(before.ru_stime),
          process_microseconds(after.ru_utime), process_microseconds(after.ru_stime), enumeration, count);
  for (unsigned index = 0; index < retained; ++index) {
    const ThreadCpu *row = &rows[index];
    fprintf(output, "%s{\"id\":%" PRIu64 ",\"user_us\":%" PRIu64 ",\"system_us\":%" PRIu64
            ",\"identifier_result\":%d,\"basic_result\":%d,\"name_result\":%d,\"name_hex\":\"",
            index == 0 ? "" : ",", row->id, row->user_us, row->system_us,
            row->identifier_result, row->basic_result, row->name_result);
    for (size_t byte = 0; byte < sizeof(row->name) && row->name[byte] != '\0'; ++byte) {
      fprintf(output, "%0*x", hexadecimal_width, (unsigned char)row->name[byte]);
    }
    fputs("\"}", output);
  }
  fputs("]}\n", output);
  if (fflush(output) != 0 || ferror(output)) {
    return EIO;
  }
  return enumeration == KERN_SUCCESS && retained == count ? 0 : EOVERFLOW;
}

static void *observe(void *unused) {
  (void)unused;
  pthread_setname_np("telar-cpu-observer");
  pthread_mutex_lock(&mutex);
  while (!stopping && observer_error == 0) {
    const struct timespec interval = {.tv_sec = 0, .tv_nsec = sample_period_ns};
    const int waited = pthread_cond_timedwait_relative_np(&condition, &mutex, &interval);
    if (waited != 0 && waited != ETIMEDOUT) {
      observer_error = waited;
      break;
    }
    if (!stopping && waited == ETIMEDOUT) {
      observer_error = snapshot("periodic");
    }
  }
  pthread_mutex_unlock(&mutex);
  return NULL;
}

int telar_thread_cpu_begin(const char *path) {
  if (path == NULL || output != NULL) {
    return EINVAL;
  }
  output = fopen(path, "wx");
  if (output == NULL) {
    return errno;
  }

  stopping = false;
  observer_error = 0;
  sequence = 0;
  uint64_t controlling_id = 0;
  pthread_threadid_np(NULL, &controlling_id);
  fprintf(output, "{\"type\":\"header\",\"version\":1,\"pid\":%d,\"controlling_id\":%" PRIu64
          ",\"period_ns\":%d,\"cpu_unit\":\"microseconds\",\"clock\":\"CLOCK_UPTIME_RAW\"}\n",
          getpid(), controlling_id, sample_period_ns);
  int result = snapshot("begin");
  if (result == 0) {
    result = pthread_create(&observer, NULL, observe, NULL);
  }
  if (result != 0) {
    fclose(output);
    output = NULL;
  }
  return result;
}

int telar_thread_cpu_end(void) {
  if (output == NULL) {
    return EINVAL;
  }
  pthread_mutex_lock(&mutex);
  stopping = true;
  // Observe the sampler while it still exists; its exit tail remains outside
  // this boundary, rather than leaving a dead port in the final enumeration.
  const int captured = snapshot("end");
  pthread_cond_signal(&condition);
  pthread_mutex_unlock(&mutex);
  const int joined = pthread_join(observer, NULL);
  if (joined != 0) {
    return joined;
  }
  fprintf(output, "{\"type\":\"footer\",\"observer_error\":%d,\"join_error\":%d,\"end_error\":%d}\n",
          observer_error, joined, captured);
  const int closed = fclose(output);
  output = NULL;
  return observer_error != 0 ? observer_error : joined != 0 ? joined : captured != 0 ? captured : closed != 0 ? EIO : 0;
}
