#pragma once

#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <limits>
#include <optional>
#include <span>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace telar::runtime {

class ProcDirectory {
public:
  explicit ProcDirectory(pid_t process) noexcept {
    std::array<char, sizeof("/proc/") + std::numeric_limits<pid_t>::digits10 + 1> path{};
    if (process > 0) {
      std::snprintf(path.data(), path.size(), "/proc/%d", process);
      directory_.reset(::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    }
  }

  bool belongsTo(uid_t user) const noexcept {
    struct stat status{};
    return directory_ && ::fstat(directory_.get(), &status) == 0 && status.st_uid == user;
  }

  std::optional<std::string_view> read(const char *name, std::span<char> buffer) const noexcept {
    FileDescriptor file{::openat(directory_.get(), name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
    if (!file) {
      return std::nullopt;
    }

    std::size_t used = 0;
    while (used < buffer.size()) {
      const auto count = ::read(file.get(), buffer.data() + used, buffer.size() - used);
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        return std::nullopt;
      }
      if (count == 0) {
        return std::string_view{buffer.data(), used};
      }
      used += static_cast<std::size_t>(count);
    }
    return std::nullopt;
  }

  std::optional<std::string_view> link(const char *name, std::span<char> buffer) const noexcept {
    const auto count = ::readlinkat(directory_.get(), name, buffer.data(), buffer.size());
    if (count <= 0 || static_cast<std::size_t>(count) >= buffer.size()) {
      return std::nullopt;
    }
    return std::string_view{buffer.data(), static_cast<std::size_t>(count)};
  }

private:
  FileDescriptor directory_;
};

struct ProcStat {
  pid_t parent = 0;
  pid_t group = 0;
  pid_t foreground = 0;
  std::uint64_t started_ticks = 0;
  std::string_view name;

  static std::optional<ProcStat> parse(std::string_view input) noexcept {
    const auto begin = input.find('(');
    const auto end = input.rfind(')');
    if (begin == std::string_view::npos || end == std::string_view::npos || end <= begin || input.size() < end + 4) {
      return std::nullopt;
    }

    ProcStat result;
    result.name = input.substr(begin + 1, end - begin - 1);
    input.remove_prefix(end + 4);
    enum class Field : unsigned { parent = 4, group = 5, foreground = 8, started = 22 };
    for (unsigned field = static_cast<unsigned>(Field::parent); field <= static_cast<unsigned>(Field::started); ++field) {
      const auto separator = input.find(' ');
      const auto word = input.substr(0, separator);
      const auto selected = static_cast<Field>(field);
      if (selected == Field::parent || selected == Field::group || selected == Field::foreground || selected == Field::started) {
        std::int64_t value = 0;
        const auto parsed = std::from_chars(word.data(), word.data() + word.size(), value);
        if (parsed.ec != std::errc{} || parsed.ptr != word.data() + word.size()) {
          return std::nullopt;
        }
        switch (selected) {
        case Field::parent: result.parent = static_cast<pid_t>(value); break;
        case Field::group: result.group = static_cast<pid_t>(value); break;
        case Field::foreground: result.foreground = static_cast<pid_t>(value); break;
        case Field::started:
          if (value < 0) {
            return std::nullopt;
          }
          result.started_ticks = static_cast<std::uint64_t>(value);
          break;
        }
      }
      if (separator == std::string_view::npos) {
        return field == static_cast<unsigned>(Field::started) ? std::optional{result} : std::nullopt;
      }
      input.remove_prefix(separator + 1);
    }
    return result;
  }
};

}
