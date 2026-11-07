module;
#include <cstddef>

#include <cstdint>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <cstdio>
#include <fcntl.h>
#include <sys/stat.h>
#include <dirent.h>
#include <sys/socket.h>

module telar.runtime.platform.process_probe;

import std;

import telar.runtime.platform.launch_program;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;


namespace telar::runtime {
namespace {

constexpr std::size_t process_stat_capacity = 4096;

}

std::optional<ProcessSnapshot> ProcessInspector::snapshot(pid_t process) const noexcept {
  ProcDirectory directory{process};
  std::array<char, process_stat_capacity> storage;
  const auto bytes = directory.read("stat", storage);
  const auto status = bytes ? ProcStat::parse(*bytes) : std::nullopt;
  if (!status || !directory.belongsTo(uid_)) {
    return std::nullopt;
  }

  static const auto ticks_per_second = ::sysconf(_SC_CLK_TCK);
  constexpr std::uint64_t microseconds_per_second = 1'000'000;
  if (ticks_per_second <= 0) {
    return std::nullopt;
  }
  const auto frequency = static_cast<std::uint64_t>(ticks_per_second);
  return ProcessSnapshot{
      .identity = {process, status->parent, status->started_ticks / frequency, (status->started_ticks % frequency) * microseconds_per_second / frequency, status->group},
      .terminal_foreground = status->foreground,
  };
}

std::optional<ProcessIdentity> ProcessInspector::peer(int socket) const noexcept {
  ucred credentials{};
  socklen_t length = sizeof(credentials);
  if (::getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 || length != sizeof(credentials) || credentials.uid != uid_) {
    return std::nullopt;
  }
  return identity(credentials.pid);
}

ProcessArguments ProcessInspector::readArguments(pid_t process, std::span<char> buffer) noexcept {
  const auto bytes = ProcDirectory{process}.read("cmdline", buffer);
  return ProcessArguments{bytes.value_or(std::string_view{})};
}

FixedText<4096> ProcessInspector::executable(pid_t process) noexcept {
  FixedText<4096> result;
  std::array<char, 4096> buffer;
  if (const auto path = ProcDirectory{process}.link("exe", buffer)) {
    result.assign(*path);
  }
  return result;
}

std::size_t ProcessInspector::groupMembers(pid_t group, std::span<pid_t> members) noexcept {
  auto *directory = ::opendir("/proc");
  if (directory == nullptr) {
    return 0;
  }

  std::size_t count = 0;
  while (const auto *entry = ::readdir(directory)) {
    const std::string_view name{entry->d_name};
    pid_t process = 0;
    const auto parsed = std::from_chars(name.data(), name.data() + name.size(), process);
    if (parsed.ec != std::errc{} || parsed.ptr != name.data() + name.size() || process <= 0) {
      continue;
    }

    if (::getpgid(process) == group) {
      members[count++] = process;
      if (count == members.size()) {
        break;
      }
    }
  }
  ::closedir(directory);
  return count;
}

FixedText<48> ProcessInspector::name(pid_t process) const noexcept {
  FixedText<48> result;
  std::array<char, process_stat_capacity> storage;
  const auto bytes = ProcDirectory{process}.read("stat", storage);
  const auto status = bytes ? ProcStat::parse(*bytes) : std::nullopt;
  if (status) {
    try {
      DisplayText16<48, false>::validate(status->name);
      result.assign(status->name);
    } catch (...) {
    }
  }
  return result;
}

FixedText<4096> ProcessInspector::directory(pid_t process) const noexcept {
  FixedText<4096> result;
  std::array<char, 4096> buffer;
  if (const auto path = ProcDirectory{process}.link("cwd", buffer); path && path->starts_with('/')) {
    result.assign(*path);
  }
  return result;
}

FixedText<4096> ProcessInspector::terminal(pid_t process) const noexcept {
  FixedText<4096> result;
  std::array<char, 4096> buffer;
  if (const auto path = ProcDirectory{process}.link("fd/0", buffer); path && path->starts_with("/dev/")) {
    result.assign(*path);
  }
  return result;
}

}
