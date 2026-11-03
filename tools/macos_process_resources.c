#include "macos_process_resources.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

enum ExitCode {
  usage_error = 2,
  resource_error = 3
};

enum HexEncoding {
  hex_digits_per_byte = 2
};

int main(int argc, char **argv) {
  if (argc != 2) {
    return usage_error;
  }

  errno = 0;
  char *end = NULL;
  long pid = strtol(argv[1], &end, 10);
  if (errno || end == argv[1] || *end || pid <= 0 || pid > INT_MAX) {
    return usage_error;
  }

  ProcessResources snapshot = process_resources((pid_t)pid);
  if (snapshot.result || snapshot.timebase_result != KERN_SUCCESS ||
      snapshot.timebase.numer == 0 || snapshot.timebase.denom == 0) {
    return resource_error;
  }

  const struct rusage_info_v4 *u = &snapshot.usage;
  char uuid[sizeof(u->ri_uuid) * hex_digits_per_byte + 1];
  for (unsigned i = 0; i < sizeof(u->ri_uuid); ++i) {
    snprintf(uuid + i * hex_digits_per_byte, hex_digits_per_byte + 1, "%0*x", hex_digits_per_byte, u->ri_uuid[i]);
  }

  printf("{\"pid\":%d,\"before_ns\":%llu,\"after_ns\":%llu,\"timebase_numer\":%"
         "u,\"timebase_denom\":%u,\"start_abstime\":%llu,\"exit_abstime\":%llu,"
         "\"uuid\":\"%s\",\"user_ticks\":%llu,\"system_ticks\":%llu,\"idle_"
         "wakeups\":%llu,\"interrupt_wakeups\":%llu,\"pageins\":%llu,"
         "\"resident_bytes\":%llu,\"footprint_bytes\":%llu,\"lifetime_max_"
         "footprint_bytes\":%llu}\n",
         snapshot.pid, snapshot.before_ns, snapshot.after_ns,
         snapshot.timebase.numer, snapshot.timebase.denom,
         u->ri_proc_start_abstime, u->ri_proc_exit_abstime, uuid,
         u->ri_user_time, u->ri_system_time, u->ri_pkg_idle_wkups,
         u->ri_interrupt_wkups, u->ri_pageins, u->ri_resident_size,
         u->ri_phys_footprint, u->ri_lifetime_max_phys_footprint);
  return 0;
}
