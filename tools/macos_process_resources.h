#pragma once

#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

typedef struct {
  pid_t pid;
  int result;
  int error;
  kern_return_t timebase_result;
  mach_timebase_info_data_t timebase;
  uint64_t before_ns;
  uint64_t after_ns;
  struct rusage_info_v4 usage;
} ProcessResources;

static inline ProcessResources process_resources(pid_t pid) {
  ProcessResources result = {.pid = pid};
  result.timebase_result = mach_timebase_info(&result.timebase);
  result.before_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  errno = 0;
  result.result =
      proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&result.usage);
  result.error = result.result == 0 ? 0 : errno;
  result.after_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  return result;
}

static inline bool process_resources_match(const ProcessResources *before, const ProcessResources *after) {
  return before->timebase_result == KERN_SUCCESS &&
         after->timebase_result == KERN_SUCCESS && before->timebase.numer > 0 &&
         before->timebase.denom > 0 &&
         before->timebase.numer == after->timebase.numer &&
         before->timebase.denom == after->timebase.denom &&
         before->result == 0 && after->result == 0 && before->pid > 0 &&
         before->pid == after->pid && before->before_ns <= before->after_ns &&
         before->after_ns <= after->before_ns &&
         after->before_ns <= after->after_ns &&
         before->usage.ri_proc_start_abstime > 0 &&
         before->usage.ri_proc_start_abstime ==
             after->usage.ri_proc_start_abstime &&
         before->usage.ri_proc_exit_abstime == 0 &&
         after->usage.ri_proc_exit_abstime == 0 &&
         memcmp(before->usage.ri_uuid, after->usage.ri_uuid,
                sizeof(before->usage.ri_uuid)) == 0 &&
         before->usage.ri_user_time <= after->usage.ri_user_time &&
         before->usage.ri_system_time <= after->usage.ri_system_time &&
         before->usage.ri_pkg_idle_wkups <= after->usage.ri_pkg_idle_wkups &&
         before->usage.ri_interrupt_wkups <= after->usage.ri_interrupt_wkups &&
         before->usage.ri_pageins <= after->usage.ri_pageins;
}

static inline double process_cpu_nanoseconds(uint64_t ticks, const ProcessResources *snapshot) {
  return (double)ticks * snapshot->timebase.numer / snapshot->timebase.denom;
}
