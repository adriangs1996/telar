module telar.runtime.platform.process_probe;

import std;
import telar.sys.posix;
import telar.sys.socket;
import telar.sys.apple;

import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime {

  ProcessArguments ProcessInspector::readArguments(pid_t process, std::span<char> buffer) noexcept {
    std::size_t length = buffer.size();
    int selector[]{CTL_KERN, KERN_PROCARGS2, process};
    if (::sysctl(selector, 3, buffer.data(), &length, nullptr, 0) != 0 || length > buffer.size()) {
      return ProcessArguments{{}};
    }

    return ProcessArguments::fromMacos(buffer.first(length));
  }

  ds::Option<ProcessSnapshot> ProcessInspector::snapshot(pid_t process) const noexcept {
    if (process <= 0) {
      return ds::none;
    }

    proc_bsdinfo information{};
    if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information) || information.pbi_uid != uid_) {
      return ds::none;
    }

    return ProcessSnapshot{
        .identity = {process, static_cast<pid_t>(information.pbi_ppid), information.pbi_start_tvsec, information.pbi_start_tvusec, static_cast<pid_t>(information.pbi_pgid)},
        .terminal_foreground = static_cast<pid_t>(information.e_tpgid),
    };
  }

  ds::Option<ProcessIdentity> ProcessInspector::peer(int socket) const noexcept {
    pid_t process = 0;
    socklen_t length = sizeof(process);
    if (::getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &process, &length) != 0 || length != sizeof(process)) {
      return ds::none;
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
      const auto& path = information.pvi_cdir.vip_path;
      const auto length = ::strnlen(path, sizeof(path));
      if (length != 0 && length < sizeof(path) && path[0] == '/') {
        result.assign({path, length});
      }
    }

    return result;
  }

  FixedText<4096> ProcessInspector::executable(pid_t process) noexcept {
    FixedText<4096> result;
    ds::Array<char, PROC_PIDPATHINFO_MAXSIZE> path{};
    const auto length = ::proc_pidpath(process, path.dataMut(), path.size());
    if (length > 0) {
      result.assign(path.data());
    }

    return result;
  }

  ListeningPorts ProcessInspector::listeningPorts(pid_t group) const noexcept {
    constexpr std::size_t maximum_group_processes = 64;
    // Listening sockets open early; a busy server's later descriptors past this bound are connections.
    constexpr std::size_t maximum_descriptors = 1024;
    ListeningPorts ports;
    ds::Array<pid_t, maximum_group_processes> members;
    ds::Array<proc_fdinfo, maximum_descriptors> descriptors;

    for (const auto member : std::span{members}.first(groupMembers(group, members.viewMut()))) {
      const auto bytes = ::proc_pidinfo(member, PROC_PIDLISTFDS, 0, descriptors.dataMut(), static_cast<int>(sizeof(descriptors)));
      if (bytes <= 0) {
        continue;
      }

      for (const auto& descriptor : std::span{descriptors}.first(std::min(descriptors.size(), static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo)))) {
        if (descriptor.proc_fdtype != PROX_FDTYPE_SOCKET) {
          continue;
        }

        socket_fdinfo information{};
        if (::proc_pidfdinfo(member, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, sizeof(information)) != sizeof(information)) {
          continue;
        }

        const auto& socket = information.psi;
        if (socket.soi_kind == SOCKINFO_TCP && socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN) {
          ports.add(ntohs(static_cast<std::uint16_t>(socket.soi_proto.pri_tcp.tcpsi_ini.insi_lport)));
        }
      }
    }

    return ports;
  }

  std::size_t ProcessInspector::groupMembers(pid_t group, std::span<pid_t> members) noexcept {
    const auto bytes = ::proc_listpids(PROC_PGRP_ONLY, static_cast<std::uint32_t>(group), members.data(), members.size_bytes());

    return bytes > 0 ? std::min(members.size(), static_cast<std::size_t>(bytes) / sizeof(pid_t)) : 0;
  }

  FixedText<4096> ProcessInspector::terminal(pid_t process) const noexcept {
    FixedText<4096> result;
    proc_bsdinfo information{};
    ds::Array<char, 128> name{};
    if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) == sizeof(information) && ::devname_r(information.e_tdev, S_IFCHR, name.dataMut(), name.size()) != nullptr) {
      ds::Array<char, 4096> path{};

      std::snprintf(path.dataMut(), path.size(), "/dev/%s", name.data());
      result.assign(path.data());
    }

    return result;
  }

}
