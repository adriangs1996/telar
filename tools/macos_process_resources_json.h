#pragma once

#include "macos_process_resources.h"
#include <stdio.h>

enum HexEncoding {
  hex_digits_per_byte = 2
};

static inline bool process_resources_write(FILE *output, const ProcessResources *snapshot) {
  if (snapshot->result != 0 || snapshot->timebase_result != KERN_SUCCESS || snapshot->timebase.numer == 0 || snapshot->timebase.denom == 0) {
    return false;
  }

  const struct rusage_info_v4 *u = &snapshot->usage;
  char uuid[sizeof(u->ri_uuid) * hex_digits_per_byte + 1];
  for (unsigned i = 0; i < sizeof(u->ri_uuid); ++i) {
    snprintf(uuid + i * hex_digits_per_byte, hex_digits_per_byte + 1, "%0*x", hex_digits_per_byte, u->ri_uuid[i]);
  }

  return fprintf(output, "{\"pid\":%d,\"before_ns\":%llu,\"after_ns\":%llu,\"timebase_numer\":%"
         "u,\"timebase_denom\":%u,\"start_abstime\":%llu,\"exit_abstime\":%llu,"
         "\"uuid\":\"%s\",\"user_ticks\":%llu,\"system_ticks\":%llu,\"idle_"
         "wakeups\":%llu,\"interrupt_wakeups\":%llu,\"pageins\":%llu,"
         "\"resident_bytes\":%llu,\"footprint_bytes\":%llu,\"lifetime_max_"
         "footprint_bytes\":%llu,\"instructions\":%llu,\"cycles\":%llu}\n",
         snapshot->pid, snapshot->before_ns, snapshot->after_ns,
         snapshot->timebase.numer, snapshot->timebase.denom,
         u->ri_proc_start_abstime, u->ri_proc_exit_abstime, uuid,
         u->ri_user_time, u->ri_system_time, u->ri_pkg_idle_wkups,
         u->ri_interrupt_wkups, u->ri_pageins, u->ri_resident_size,
         u->ri_phys_footprint, u->ri_lifetime_max_phys_footprint,
         u->ri_instructions, u->ri_cycles) > 0;
}
