module telar.runtime.host.process_probe;

import std;
import telar.sys.socket;
import telar.sys.process;
import telar.sys.linux_api;
import telar.sys.posix;

import telar.runtime.host.proc_file;
import telar.wire.vocabulary;
import telar.platform.listening;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    constexpr std::size_t process_stat_capacity = 4096;

  }

  ds::Option<ProcessSnapshot> ProcessInspector::snapshot(pid_t process) const noexcept {
    ProcDirectory directory{process};
    ds::Array<char, process_stat_capacity> storage;
    const auto bytes = directory.read("stat", storage.viewMut());
    const auto status = bytes ? ProcStat::parse(*bytes) : ds::none;
    if (!status || !directory.belongsTo(uid_)) {
      return ds::none;
    }

    static const auto ticks_per_second = ::sysconf(_SC_CLK_TCK);
    constexpr std::uint64_t microseconds_per_second = 1'000'000;
    if (ticks_per_second <= 0) {
      return ds::none;
    }
    const auto frequency = static_cast<std::uint64_t>(ticks_per_second);
    return ProcessSnapshot{
        .identity = {process, status->parent, status->started_ticks / frequency, (status->started_ticks % frequency) * microseconds_per_second / frequency, status->group},
        .terminal_foreground = status->foreground,
    };
  }

  ds::Option<ProcessIdentity> ProcessInspector::peer(int socket) const noexcept {
    ucred credentials{};
    socklen_t length = sizeof(credentials);
    if (::getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 || length != sizeof(credentials) || credentials.uid != uid_) {
      return ds::none;
    }
    return identity(credentials.pid);
  }

  ProcessArguments ProcessInspector::readArguments(pid_t process, std::span<char> buffer) noexcept {
    const auto bytes = ProcDirectory{process}.read("cmdline", buffer);
    return ProcessArguments{bytes.valueOr(std::string_view{})};
  }

  FixedText<4096> ProcessInspector::executable(pid_t process) noexcept {
    FixedText<4096> result;
    ds::Array<char, 4096> buffer;
    if (const auto path = ProcDirectory{process}.link("exe", buffer.viewMut())) {
      result.assign(*path);
    }
    return result;
  }

  ListeningPorts ProcessInspector::listeningPorts(pid_t group) const noexcept {
    constexpr std::size_t maximum_group_ports = 256;
    ListeningPorts ports;
    ds::Array<std::uint16_t, maximum_group_ports> found{};

    for (const auto port : std::span{found}.first(groupListeningPorts(uid_, group, found.viewMut()))) {
      ports.add(port);
    }

    return ports;
  }

  std::size_t ProcessInspector::groupMembers(pid_t group, std::span<pid_t> members) noexcept {
    return processGroupMembers(group, members);
  }

  FixedText<48> ProcessInspector::name(pid_t process) const noexcept {
    FixedText<48> result;
    ds::Array<char, process_stat_capacity> storage;
    const auto bytes = ProcDirectory{process}.read("stat", storage.viewMut());
    const auto status = bytes ? ProcStat::parse(*bytes) : ds::none;
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
    ds::Array<char, 4096> buffer;
    if (const auto path = ProcDirectory{process}.link("cwd", buffer.viewMut()); path && path->starts_with('/')) {
      result.assign(*path);
    }
    return result;
  }

  FixedText<4096> ProcessInspector::terminal(pid_t process) const noexcept {
    FixedText<4096> result;
    ds::Array<char, 4096> buffer;
    if (const auto path = ProcDirectory{process}.link("fd/0", buffer.viewMut()); path && path->starts_with("/dev/")) {
      result.assign(*path);
    }
    return result;
  }

}
