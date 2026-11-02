#include "../process_inspector.hpp"
#include "../../text/utf8.hpp"
#include "../process_arguments.hpp"
#include <cstring>
#include <cstdio>
#include <sys/stat.h>
#include <libproc.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <unistd.h>

namespace telar::runtime {

ProcessArguments ProcessInspector::readArguments(pid_t process, std::span<char> buffer) noexcept {
  std::size_t length = buffer.size();
  int selector[]{CTL_KERN, KERN_PROCARGS2, process};
  if (::sysctl(selector, 3, buffer.data(), &length, nullptr, 0) != 0 || length > buffer.size()) {
    return ProcessArguments{{}};
  }

  return ProcessArguments::fromMacos(buffer.first(length));
}

std::optional<ProcessSnapshot> ProcessInspector::snapshot(pid_t process) const noexcept {
  if (process <= 0) {
    return std::nullopt;
  }

  proc_bsdinfo information{};
  if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information) || information.pbi_uid != uid_) {
    return std::nullopt;
  }

  return ProcessSnapshot{
      .identity = {process, static_cast<pid_t>(information.pbi_ppid), information.pbi_start_tvsec, information.pbi_start_tvusec, static_cast<pid_t>(information.pbi_pgid)},
      .terminal_foreground = static_cast<pid_t>(information.e_tpgid),
  };
}

std::optional<ProcessIdentity> ProcessInspector::peer(int socket) const noexcept {
  pid_t process = 0;
  socklen_t length = sizeof(process);
  if (::getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &process, &length) != 0 || length != sizeof(process)) {
    return std::nullopt;
  }

  return identity(process);
}

FixedText<48> ProcessInspector::name(pid_t process) const noexcept {
  FixedText<48> result;
  proc_bsdinfo information{};
  if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) == sizeof(information)) {
    const std::string_view candidate{information.pbi_comm, ::strnlen(information.pbi_comm, sizeof(information.pbi_comm))};
    try {
      DisplayText16<48, false>::validate(candidate);
      result.assign(candidate);
    } catch (...) {
    }
  }

  return result;
}

FixedText<4096> ProcessInspector::directory(pid_t process) const noexcept {
  FixedText<4096> result;
  proc_vnodepathinfo information{};
  if (::proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &information, sizeof(information)) == sizeof(information)) {
    const auto &path = information.pvi_cdir.vip_path;
    const auto length = ::strnlen(path, sizeof(path));
    if (length != 0 && length < sizeof(path) && path[0] == '/') {
      result.assign({path, length});
    }
  }

  return result;
}

FixedText<4096> ProcessInspector::executable(pid_t process) noexcept {
  FixedText<4096> result;
  std::array<char, PROC_PIDPATHINFO_MAXSIZE> path{};
  const auto length = ::proc_pidpath(process, path.data(), path.size());
  if (length > 0) {
    result.assign(path.data());
  }
  return result;
}

std::size_t ProcessInspector::groupMembers(pid_t group, std::span<pid_t> members) noexcept {
  const auto bytes = ::proc_listpids(PROC_PGRP_ONLY, static_cast<std::uint32_t>(group), members.data(), members.size_bytes());
  return bytes > 0 ? std::min(members.size(), static_cast<std::size_t>(bytes) / sizeof(pid_t)) : 0;
}

FixedText<4096> ProcessInspector::terminal(pid_t process) const noexcept {
  FixedText<4096> result;
  proc_bsdinfo information{};
  std::array<char, 128> name{};
  if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) == sizeof(information) && ::devname_r(information.e_tdev, S_IFCHR, name.data(), name.size()) != nullptr) {
    std::array<char, 4096> path{};
    std::snprintf(path.data(), path.size(), "/dev/%s", name.data());
    result.assign(path.data());
  }
  return result;
}

}
