#pragma once

#include "line.hpp"
#include "telar_base/memory/allocation_statistics.hpp"
#if defined(__APPLE__)
#include <mach/mach.h>
#else
#include "../platform/linux/proc_file.hpp"
#endif

namespace telar::runtime::diagnostics {

inline std::uint64_t residentBytes() noexcept {
#if defined(__APPLE__)
  task_vm_info_data_t information{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (::task_info(::mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&information), &count) != KERN_SUCCESS) {
    return 0;
  }

  return information.resident_size;
#else
  std::array<char, 256> buffer;
  const auto bytes = ProcDirectory{::getpid()}.read("statm", buffer);
  if (!bytes) {
    return 0;
  }
  const auto separator = bytes->find(' ');
  if (separator == std::string_view::npos) {
    return 0;
  }

  std::uint64_t pages = 0;
  const auto resident = bytes->substr(separator + 1);
  const auto parsed = std::from_chars(resident.data(), resident.data() + resident.size(), pages);
  const auto page_size = ::sysconf(_SC_PAGESIZE);
  return parsed.ec == std::errc{} && page_size > 0 ? pages * static_cast<std::uint64_t>(page_size) : 0;
#endif
}

inline void writeMemorySample(Line &line, const AllocationStatistics &statistics) {
  line.field("heap_live_bytes", statistics.live_bytes);
  line.field("heap_live_allocs", statistics.live_allocations);
  line.field("heap_allocs", statistics.total.count);
  line.field("heap_alloc_bytes", statistics.total.bytes);
  const auto &interactive = statistics.paths[static_cast<std::size_t>(AllocationPath::interactive)];
  const auto &terminal = statistics.interactive_terminal;
  line.field("interactive_allocs", interactive.count);
  line.field("interactive_alloc_bytes", interactive.bytes);
  line.field("interactive_vt_allocs", terminal.count);
  line.field("interactive_vt_alloc_bytes", terminal.bytes);
  line.field("interactive_telar_allocs", interactive.count - terminal.count);
  line.field("interactive_telar_alloc_bytes", interactive.bytes - terminal.bytes);

  const auto &media = statistics.paths[static_cast<std::size_t>(AllocationPath::media)];
  line.field("media_allocs", media.count);
  line.field("media_alloc_bytes", media.bytes);
  const auto &observation = statistics.paths[static_cast<std::size_t>(AllocationPath::observation)];
  line.field("observation_allocs", observation.count);
  line.field("observation_alloc_bytes", observation.bytes);
  const auto &other = statistics.paths[static_cast<std::size_t>(AllocationPath::other)];
  line.field("other_allocs", other.count);
  line.field("other_alloc_bytes", other.bytes);
}

}
