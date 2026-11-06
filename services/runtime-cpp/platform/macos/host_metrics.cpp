module;

#include <concepts>
#include <cstdint>
#include <optional>
#include "telar_platform/trace.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <algorithm>
#include <limits>
#include <mach/mach.h>
#include <memory>
#include <sys/sysctl.h>
#include <unistd.h>

module telar.runtime.platform.stream_read_buffer;



namespace telar::runtime {
namespace {

std::optional<std::int32_t> integerValue(CFDictionaryRef dictionary, CFStringRef key) noexcept {
  const auto value = CFDictionaryGetValue(dictionary, key);
  if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID()) {
    return std::nullopt;
  }

  std::int32_t integer = 0;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &integer)) {
    return std::nullopt;
  }

  return integer;
}

std::optional<std::uint8_t> batteryPercent() noexcept {
  const std::unique_ptr<const void, decltype(&CFRelease)> information{IOPSCopyPowerSourcesInfo(), &CFRelease};
  if (!information) {
    return std::nullopt;
  }

  const std::unique_ptr<const void, decltype(&CFRelease)> sources{IOPSCopyPowerSourcesList(information.get()), &CFRelease};
  if (!sources) {
    return std::nullopt;
  }

  const auto array = static_cast<CFArrayRef>(sources.get());
  const auto count = CFArrayGetCount(array);
  for (CFIndex index = 0; index < count; ++index) {
    const auto description = IOPSGetPowerSourceDescription(information.get(), CFArrayGetValueAtIndex(array, index));
    if (description == nullptr) {
      continue;
    }

    const auto current = integerValue(description, CFSTR(kIOPSCurrentCapacityKey));
    const auto maximum = integerValue(description, CFSTR(kIOPSMaxCapacityKey));
    if (!current || !maximum || *current < 0 || *maximum <= 0) {
      continue;
    }

    return static_cast<std::uint8_t>(std::min<std::int64_t>(100, static_cast<std::int64_t>(*current) * 100 / *maximum));
  }

  return std::nullopt;
}

template <typename Integer>
Integer systemCounter(const char *name) noexcept {
  Integer value = 0;
  auto size = sizeof(value);
  if (::sysctlbyname(name, &value, &size, nullptr, 0) != 0 || size != sizeof(value)) {
    return 0;
  }

  return value;
}

}

std::optional<HostCounters> NativeHostMetrics::read() noexcept {
  TELAR_TRACE("metrics.readHost");
  const auto host = ::mach_host_self();
  host_cpu_load_info_data_t cpu{};
  mach_msg_type_number_t cpu_words = HOST_CPU_LOAD_INFO_COUNT;
  const auto cpu_result = ::host_statistics64(host, HOST_CPU_LOAD_INFO, reinterpret_cast<host_info64_t>(&cpu), &cpu_words);
  vm_statistics64_data_t memory{};
  mach_msg_type_number_t memory_words = HOST_VM_INFO64_COUNT;
  const auto memory_result = ::host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&memory), &memory_words);
  ::mach_port_deallocate(::mach_task_self(), host);
  if (cpu_result != KERN_SUCCESS || memory_result != KERN_SUCCESS) {
    return std::nullopt;
  }

  const auto busy = static_cast<std::uint64_t>(cpu.cpu_ticks[CPU_STATE_USER]) + cpu.cpu_ticks[CPU_STATE_SYSTEM] + cpu.cpu_ticks[CPU_STATE_NICE];
  const auto used_pages = static_cast<std::uint64_t>(memory.active_count) + memory.wire_count + memory.compressor_page_count;
  const auto cpu_count = std::clamp(systemCounter<int>("hw.logicalcpu"), 0, static_cast<int>(std::numeric_limits<std::uint16_t>::max()));
  return HostCounters{
      .busy_ticks = busy,
      .total_ticks = busy + cpu.cpu_ticks[CPU_STATE_IDLE],
      .memory_used_bytes = used_pages * static_cast<std::uint64_t>(::getpagesize()),
      .memory_total_bytes = systemCounter<std::uint64_t>("hw.memsize"),
      .cpu_count = static_cast<std::uint16_t>(cpu_count),
      .battery_percent = batteryPercent(),
  };
}

}
