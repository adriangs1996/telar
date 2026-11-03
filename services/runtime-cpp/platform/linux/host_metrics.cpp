#include "../host_metrics.hpp"
#include "telar_platform/directory_stream.hpp"
#include "telar_platform/trace.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <limits.h>
#include <limits>
#include <string_view>
#include <sys/sysinfo.h>
#include <unistd.h>

namespace telar::runtime {
namespace {

template <std::size_t Capacity>
bool readText(const char *path, std::array<char, Capacity> &buffer) noexcept {
  FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC)};
  if (!file) {
    return false;
  }

  const auto count = ::read(file.get(), buffer.data(), buffer.size() - 1);
  if (count <= 0) {
    return false;
  }
  buffer[count] = '\0';
  return true;
}

std::optional<std::uint8_t> batteryPercent() noexcept {
  try {
    DirectoryStream directory{FileDescriptor{::open("/sys/class/power_supply", O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
    std::array<char, PATH_MAX> path;
    std::array<char, 64> text;
    while (const auto *entry = directory.next()) {
      std::snprintf(path.data(), path.size(), "/sys/class/power_supply/%s/type", entry->d_name);
      if (!readText(path.data(), text) || std::string_view{text.data()} != "Battery\n") {
        continue;
      }

      std::snprintf(path.data(), path.size(), "/sys/class/power_supply/%s/capacity", entry->d_name);
      if (!readText(path.data(), text)) {
        continue;
      }
      unsigned value = 0;
      const auto parsed = std::from_chars(text.data(), text.data() + std::strlen(text.data()), value);
      constexpr unsigned maximum_percent = 100;
      if (parsed.ec == std::errc{} && value <= maximum_percent) {
        return static_cast<std::uint8_t>(value);
      }
    }
  } catch (...) {
  }
  return std::nullopt;
}

}

std::optional<HostCounters> NativeHostMetrics::read() noexcept {
  TELAR_TRACE("metrics.readHost");
  std::array<char, 16 * 1024> buffer;
  if (!readText("/proc/stat", buffer)) {
    return std::nullopt;
  }

  enum class CpuField : std::size_t { user, nice, system, idle, io_wait, irq, soft_irq, stolen, count };
  std::array<unsigned long long, static_cast<std::size_t>(CpuField::count)> ticks{};
  const auto found = std::sscanf(buffer.data(), "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &ticks[0], &ticks[1], &ticks[2], &ticks[3], &ticks[4], &ticks[5], &ticks[6], &ticks[7]);
  if (found < static_cast<int>(CpuField::idle) + 1) {
    return std::nullopt;
  }

  std::uint64_t total_ticks = 0;
  for (const auto value : ticks) {
    total_ticks += value;
  }
  const auto idle_ticks = ticks[static_cast<std::size_t>(CpuField::idle)] + ticks[static_cast<std::size_t>(CpuField::io_wait)];
  if (!readText("/proc/meminfo", buffer)) {
    return std::nullopt;
  }

  unsigned long long total_kib = 0;
  unsigned long long available_kib = 0;
  std::string_view remaining{buffer.data()};
  while (!remaining.empty()) {
    if (remaining.starts_with("MemTotal:")) {
      std::sscanf(remaining.data(), "MemTotal: %llu", &total_kib);
    } else if (remaining.starts_with("MemAvailable:")) {
      std::sscanf(remaining.data(), "MemAvailable: %llu", &available_kib);
    }
    const auto newline = remaining.find('\n');
    remaining = newline == std::string_view::npos ? std::string_view{} : remaining.substr(newline + 1);
  }
  if (total_kib == 0 || available_kib > total_kib) {
    return std::nullopt;
  }

  constexpr std::uint64_t bytes_per_kib = 1024;
  const auto cpu_count = std::clamp<long>(::sysconf(_SC_NPROCESSORS_ONLN), 0, std::numeric_limits<std::uint16_t>::max());
  return HostCounters{
      .busy_ticks = total_ticks - idle_ticks,
      .total_ticks = total_ticks,
      .memory_used_bytes = (total_kib - available_kib) * bytes_per_kib,
      .memory_total_bytes = total_kib * bytes_per_kib,
      .cpu_count = static_cast<std::uint16_t>(cpu_count),
      .battery_percent = batteryPercent(),
  };
}

}
