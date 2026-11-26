module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.host.host_metrics;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.platform.fs;
import telar.platform.primitives;
import telar.base.memory.containers;
import telar.base.text;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    template <std::size_t Capacity>
    bool readText(const char* path, ds::Array<char, Capacity>& buffer) noexcept {
      FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC)};
      if (!file) {
        return false;
      }

      const auto count = ::read(file.get(), buffer.dataMut(), buffer.size() - 1);
      if (count <= 0) {
        return false;
      }
      buffer.atMut(count) = '\0';
      return true;
    }

    ds::Option<std::uint8_t> batteryPercent() noexcept {
      try {
        DirectoryStream directory{FileDescriptor{::open("/sys/class/power_supply", O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
        ds::Array<char, PATH_MAX> path;
        ds::Array<char, 64> text;
        while (const auto* entry = directory.next()) {
          std::snprintf(path.dataMut(), path.size(), "/sys/class/power_supply/%s/type", entry->d_name);
          if (!readText(path.data(), text) || std::string_view{text.data()} != "Battery\n") {
            continue;
          }

          std::snprintf(path.dataMut(), path.size(), "/sys/class/power_supply/%s/capacity", entry->d_name);
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
      return ds::none;
    }

  }

  ds::Option<HostCounters> NativeHostMetrics::read() noexcept {
    TELAR_TRACE("metrics.readHost");
    ds::Array<char, 16 * 1024> buffer;
    if (!readText("/proc/stat", buffer)) {
      return ds::none;
    }

    enum class CpuField : std::size_t {
      user,
      nice,
      system,
      idle,
      io_wait,
      irq,
      soft_irq,
      stolen,
      count,
    };
    ds::Array<unsigned long long, static_cast<std::size_t>(CpuField::count)> ticks{};
    const auto found = std::sscanf(buffer.data(), "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &ticks.atMut(0), &ticks.atMut(1), &ticks.atMut(2), &ticks.atMut(3), &ticks.atMut(4), &ticks.atMut(5), &ticks.atMut(6), &ticks.atMut(7));
    if (found < static_cast<int>(CpuField::idle) + 1) {
      return ds::none;
    }

    std::uint64_t total_ticks = 0;
    for (const auto value : ticks) {
      total_ticks += value;
    }
    const auto idle_ticks = ticks[static_cast<std::size_t>(CpuField::idle)] + ticks[static_cast<std::size_t>(CpuField::io_wait)];
    if (!readText("/proc/meminfo", buffer)) {
      return ds::none;
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
      return ds::none;
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

  namespace {

    constexpr std::uint64_t sector_bytes = 512;

    // The whole of a /proc file into the buffer, which must hold it; none when it does not.
    tbc::val_a<ds::Option<std::string_view>> readWhole(const char* path, tbc::val_a<std::span<char>> buffer) noexcept {
      FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC)};
      if (!file) {
        return ds::none;
      }

      std::size_t used = 0;

      while (used < buffer.size()) {
        const auto count = ::read(file.get(), buffer.data() + used, buffer.size() - used);
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count < 0) {
          return ds::none;
        }

        if (count == 0) {
          return std::string_view{buffer.data(), used};
        }

        used += static_cast<std::size_t>(count);
      }

      return ds::none;
    }

    template <typename Visit>
    void eachLine(std::string_view text, Visit&& visit) {
      while (!text.empty()) {
        const auto newline = text.find('\n');

        visit(text.substr(0, newline));
        text = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
      }
    }

    // The words of a line, separated by spaces, into `words`; returns how many it found.
    template <std::size_t Capacity>
    std::size_t splitWords(tbc::val_a<std::string_view> line, tbc::mut_a<ds::Array<std::string_view, Capacity>> words) noexcept {
      std::size_t count = 0;

      while (count < Capacity) {
        const auto first = line.find_first_not_of(' ');
        if (first == std::string_view::npos) {
          break;
        }

        line.remove_prefix(first);
        const auto end = line.find(' ');

        words.atMut(count++) = line.substr(0, end);
        line = end == std::string_view::npos ? std::string_view{} : line.substr(end);
      }

      return count;
    }

    std::uint64_t number(std::string_view word) noexcept {
      return parseExact<std::uint64_t>(word).valueOr(0);
    }

    bool readCores(HostDetail& detail, std::span<char> buffer) noexcept {
      const auto text = readWhole("/proc/stat", buffer);
      if (!text) {
        return false;
      }

      detail.core_count = 0;
      eachLine(*text, [&](std::string_view line) {
        // "cpuN user nice system idle iowait irq softirq steal"; the aggregate "cpu " line is skipped.
        if (!line.starts_with("cpu") || line.size() < 4 || line[3] == ' ' || detail.core_count == HostDetail::maximum_cores) {
          return;
        }

        ds::Array<std::string_view, 9> words;
        const auto count = splitWords(line, words);
        if (count < 5) {
          return;
        }

        std::uint64_t total = 0;
        for (std::size_t index = 1; index < count; ++index) {
          total += number(words[index]);
        }

        const auto idle = number(words[4]) + (count > 5 ? number(words[5]) : 0);

        detail.cores.atMut(detail.core_count++) = {.busy = total - std::min(idle, total), .total = total};
      });

      return detail.core_count != 0;
    }

    bool readMemory(HostDetail& detail, std::span<char> buffer) noexcept {
      const auto text = readWhole("/proc/meminfo", buffer);
      if (!text) {
        return false;
      }

      std::uint64_t total = 0;
      std::uint64_t available = 0;
      std::uint64_t cached = 0;
      std::uint64_t swap_total = 0;
      std::uint64_t swap_free = 0;

      eachLine(*text, [&](std::string_view line) {
        ds::Array<std::string_view, 3> words;
        if (splitWords(line, words) < 2) {
          return;
        }

        const auto value = number(words[1]) * 1024;
        if (words[0] == "MemTotal:") {
          total = value;
        } else if (words[0] == "MemAvailable:") {
          available = value;
        } else if (words[0] == "Cached:" || words[0] == "Buffers:") {
          cached += value;
        } else if (words[0] == "SwapTotal:") {
          swap_total = value;
        } else if (words[0] == "SwapFree:") {
          swap_free = value;
        }
      });

      if (total == 0) {
        return false;
      }

      detail.memory_total_bytes = total;
      detail.memory_available_bytes = std::min(available, total);
      detail.memory_used_bytes = total - detail.memory_available_bytes;
      detail.memory_cached_bytes = cached;
      detail.swap_total_bytes = swap_total;
      detail.swap_used_bytes = swap_total - std::min(swap_free, swap_total);
      return true;
    }

    // A path of /proc/mounts, whose spaces, tabs, newlines and backslashes are octal escapes.
    template <std::size_t Capacity>
    bool unescape(std::string_view escaped, FixedText<Capacity>& output) noexcept {
      ds::Array<char, Capacity> bytes;
      std::size_t length = 0;

      for (std::size_t index = 0; index < escaped.size(); ++index) {
        if (length == Capacity) {
          return false;
        }

        auto byte = escaped[index];
        if (byte == '\\' && index + 3 < escaped.size()) {
          const auto digits = escaped.substr(index + 1, 3);
          unsigned value = 0;
          const auto parsed = std::from_chars(digits.data(), digits.data() + digits.size(), value, 8);
          if (parsed.ec == std::errc{} && parsed.ptr == digits.data() + digits.size() && value < 256) {
            byte = static_cast<char>(value);
            index += 3;
          }
        }

        bytes.atMut(length++) = byte;
      }

      output.assign(utf8Prefix({bytes.data(), length}, Capacity));
      return true;
    }

    void readMounts(HostDetail& detail, std::span<char> buffer) noexcept {
      detail.mount_count = 0;
      const auto text = readWhole("/proc/self/mounts", buffer);
      if (!text) {
        return;
      }

      eachLine(*text, [&](std::string_view line) {
        ds::Array<std::string_view, 3> words;
        if (detail.mount_count == HostDetail::maximum_mounts || splitWords(line, words) < 3 || !words[0].starts_with("/dev/") || words[2] == "squashfs") {
          return;
        }

        MountUsage usage{};
        if (!unescape(words[1], usage.path) || !unescape(words[0], usage.device)) {
          return;
        }

        // A device mounted twice, as a bind mount, is listed once.
        for (std::size_t index = 0; index < detail.mount_count; ++index) {
          if (detail.mounts[index].device == usage.device) {
            return;
          }
        }

        ds::Array<char, 129> path{};
        struct statvfs status{};

        std::memcpy(path.dataMut(), usage.path.view().data(), usage.path.view().size());
        if (::statvfs(path.data(), &status) != 0 || status.f_blocks == 0) {
          return;
        }

        const auto block = static_cast<std::uint64_t>(status.f_frsize);

        usage.type.assign(utf8Prefix(words[2], 16));
        usage.total_bytes = status.f_blocks * block;
        usage.used_bytes = (status.f_blocks - std::min<std::uint64_t>(status.f_bfree, status.f_blocks)) * block;
        usage.available_bytes = status.f_bavail * block;
        detail.mounts.atMut(detail.mount_count++) = usage;
      });
    }

    // Sectors read and written by the physical disks: a device with a `device` link in /sys/block,
    // so that loop, device-mapper and RAID layers are not counted twice.
    void readDisks(HostDetail& detail, std::span<char> buffer) noexcept {
      detail.disk_read_bytes = 0;
      detail.disk_written_bytes = 0;
      const auto text = readWhole("/proc/diskstats", buffer);
      if (!text) {
        return;
      }

      eachLine(*text, [&](std::string_view line) {
        ds::Array<std::string_view, 10> words;
        if (splitWords(line, words) < 10 || words[2].size() > 64) {
          return;
        }

        ds::Array<char, 96> path{};

        std::snprintf(path.dataMut(), path.size(), "/sys/block/%.*s/device", static_cast<int>(words[2].size()), words[2].data());
        if (::access(path.data(), F_OK) != 0) {
          return;
        }

        detail.disk_read_bytes += number(words[5]) * sector_bytes;
        detail.disk_written_bytes += number(words[9]) * sector_bytes;
      });
    }

    void readInterfaces(HostDetail& detail, std::span<char> buffer) noexcept {
      detail.interface_count = 0;
      const auto text = readWhole("/proc/net/dev", buffer);
      if (!text) {
        return;
      }

      eachLine(*text, [&](std::string_view line) {
        // "  eth0: rx_bytes rx_packets errs drop fifo frame compressed multicast tx_bytes ..."
        const auto colon = line.find(':');
        if (colon == std::string_view::npos || detail.interface_count == HostDetail::maximum_interfaces) {
          return;
        }

        const auto name = line.substr(0, colon).substr(std::min(line.find_first_not_of(' '), colon));
        ds::Array<std::string_view, 9> words;
        if (name.empty() || name == "lo" || splitWords(line.substr(colon + 1), words) < 9) {
          return;
        }

        const auto received = number(words[0]);
        const auto sent = number(words[8]);
        if (received == 0 && sent == 0) {
          return;
        }

        auto& counters = detail.interfaces.atMut(detail.interface_count++);

        counters.name.assign(utf8Prefix(name, 16));
        counters.received_bytes = received;
        counters.sent_bytes = sent;
      });
    }

  }

  bool NativeHostDetail::read(HostDetail& detail) noexcept {
    TELAR_TRACE("metrics.readHostDetail");
    if (!readCores(detail, buffer_.viewMut()) || !readMemory(detail, buffer_.viewMut())) {
      return false;
    }

    readMounts(detail, buffer_.viewMut());
    readDisks(detail, buffer_.viewMut());
    readInterfaces(detail, buffer_.viewMut());
    return true;
  }

}
