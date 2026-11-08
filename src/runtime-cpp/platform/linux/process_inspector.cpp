module;
#include <cerrno>
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

struct ListeningSocket {
  std::uint64_t inode = 0;
  std::uint16_t port = 0;
};

template <typename Integer>
bool parseNumber(std::string_view text, Integer &value, int base) noexcept {
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value, base);
  return parsed.ec == std::errc{} && parsed.ptr == text.data() + text.size();
}

// One row of /proc/net/tcp or tcp6: `sl local remote st tx:rx tr:when retransmits uid timeout inode`.
std::optional<ListeningSocket> parseListening(std::string_view line, uid_t user) noexcept {
  constexpr unsigned listen_state = 0x0a;
  std::array<std::string_view, 10> fields;
  for (auto &field : fields) {
    const auto first = line.find_first_not_of(' ');
    if (first == std::string_view::npos) {
      return std::nullopt;
    }

    line.remove_prefix(first);
    field = line.substr(0, line.find(' '));
    line.remove_prefix(field.size());
  }

  const auto separator = fields[1].rfind(':');
  unsigned state = 0;
  uid_t owner = 0;
  ListeningSocket socket;
  if (separator == std::string_view::npos || !parseNumber(fields[3], state, 16) || state != listen_state || !parseNumber(fields[7], owner, 10) || owner != user || !parseNumber(fields[1].substr(separator + 1), socket.port, 16) || !parseNumber(fields[9], socket.inode, 10) || socket.inode == 0) {
    return std::nullopt;
  }

  return socket;
}

// Appends the listening sockets `user` owns in one kernel TCP table.
std::size_t readListening(const char *path, uid_t user, std::span<ListeningSocket> sockets, std::size_t count) noexcept {
  FileDescriptor file{::open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)};
  if (!file) {
    return count;
  }

  std::array<char, 16 * 1024> buffer;
  std::size_t kept = 0;
  bool header = true;
  while (count < sockets.size()) {
    const auto read = ::read(file.get(), buffer.data() + kept, buffer.size() - kept);
    if (read < 0 && errno == EINTR) {
      continue;
    }

    if (read <= 0) {
      break;
    }

    std::string_view text{buffer.data(), kept + static_cast<std::size_t>(read)};
    for (auto newline = text.find('\n'); newline != std::string_view::npos && count < sockets.size(); newline = text.find('\n')) {
      if (!header) {
        if (const auto socket = parseListening(text.substr(0, newline), user)) {
          sockets[count++] = *socket;
        }
      }

      header = false;
      text.remove_prefix(newline + 1);
    }

    // A row longer than the buffer is not a TCP table row.
    if (text.size() == buffer.size()) {
      break;
    }

    kept = text.size();
    std::memmove(buffer.data(), text.data(), kept);
  }

  return count;
}

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

ListeningPorts ProcessInspector::listeningPorts(pid_t group) const noexcept {
  constexpr std::size_t maximum_group_processes = 64;
  constexpr std::size_t maximum_sockets = 256;
  ListeningPorts ports;
  std::array<ListeningSocket, maximum_sockets> sockets;
  auto count = readListening("/proc/net/tcp", uid_, sockets, 0);
  count = readListening("/proc/net/tcp6", uid_, sockets, count);
  if (count == 0) {
    return ports;
  }

  const auto listening = std::span{sockets}.first(count);
  std::array<pid_t, maximum_group_processes> members;
  for (const auto member : std::span{members}.first(groupMembers(group, members))) {
    std::array<char, sizeof("/proc//fd") + std::numeric_limits<pid_t>::digits10 + 1> path{};
    std::snprintf(path.data(), path.size(), "/proc/%d/fd", member);
    auto *directory = ::opendir(path.data());
    if (directory == nullptr) {
      continue;
    }

    constexpr std::string_view prefix = "socket:[";
    while (const auto *entry = ::readdir(directory)) {
      std::array<char, 64> target;
      const auto length = ::readlinkat(::dirfd(directory), entry->d_name, target.data(), target.size());
      const std::string_view link{target.data(), length > 0 ? static_cast<std::size_t>(length) : 0};
      std::uint64_t inode = 0;
      if (!link.starts_with(prefix) || !link.ends_with(']') || !parseNumber(link.substr(prefix.size(), link.size() - prefix.size() - 1), inode, 10)) {
        continue;
      }

      const auto found = std::ranges::find(listening, inode, &ListeningSocket::inode);
      if (found != listening.end()) {
        ports.add(found->port);
      }
    }
    ::closedir(directory);
  }

  return ports;
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
