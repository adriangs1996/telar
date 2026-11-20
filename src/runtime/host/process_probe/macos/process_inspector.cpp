module telar.runtime.host.process_probe;

import std;
import telar.sys.posix;
import telar.sys.socket;
import telar.sys.apple;

import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // A NUL-padded field's text: up to its first NUL, or all of it.
    std::string_view fieldText(std::span<const char> field) noexcept {
      const auto end = std::ranges::find(field, '\0');

      return {field.data(), static_cast<std::size_t>(end - field.begin())};
    }

  }

  ProcessArguments ProcessInspector::readArguments(pid_t process, std::span<char> buffer) noexcept {
    std::size_t length = buffer.size();
    ds::Array selector{CTL_KERN, KERN_PROCARGS2, process};
    if (::sysctl(selector.dataMut(), static_cast<unsigned>(selector.size()), buffer.data(), &length, nullptr, 0) != 0 || length > buffer.size()) {
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
        .identity = {.pid = process, .parent = static_cast<pid_t>(information.pbi_ppid), .started_seconds = information.pbi_start_tvsec, .started_microseconds = information.pbi_start_tvusec, .process_group = static_cast<pid_t>(information.pbi_pgid)},
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

  FixedText<process_name_bytes> ProcessInspector::name(pid_t process) const noexcept { // NOLINT(readability-convert-member-functions-to-static): the Linux definition is const too, and both share one declaration
    FixedText<process_name_bytes> result;
    proc_bsdinfo information{};
    if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) == sizeof(information)) {
      const auto candidate = fieldText(information.pbi_comm);

      try {
        DisplayText16<process_name_bytes, false>::validate(candidate);
        result.assign(candidate);
      } catch (...) { // NOLINT(bugprone-empty-catch): a name that is not display text is left out
      }
    }

    return result;
  }

  // A vnode's path always fits the paths an inspector reports.
  static_assert(sizeof(std::declval<proc_vnodepathinfo>().pvi_cdir.vip_path) <= process_path_bytes);

  FixedText<process_path_bytes> ProcessInspector::directory(pid_t process) const noexcept { // NOLINT(readability-convert-member-functions-to-static,bugprone-exception-escape): the Linux definition is const too, and both share one declaration; assign throws only past its capacity, which a vnode's path never reaches
    FixedText<process_path_bytes> result;
    proc_vnodepathinfo information{};
    if (::proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &information, sizeof(information)) == sizeof(information)) {
      const auto& field = information.pvi_cdir.vip_path;
      const auto path = fieldText(field);
      if (!path.empty() && path.size() < sizeof(field) && path.front() == '/') {
        result.assign(path);
      }
    }

    return result;
  }

  // proc_pidpath's path, terminated, always fits the paths an inspector reports.
  static_assert(PROC_PIDPATHINFO_MAXSIZE <= process_path_bytes);

  FixedText<process_path_bytes> ProcessInspector::executable(pid_t process) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which proc_pidpath's path never reaches
    FixedText<process_path_bytes> result;
    ds::Array<char, PROC_PIDPATHINFO_MAXSIZE> path{};
    const auto length = ::proc_pidpath(process, path.dataMut(), path.size());
    if (length > 0) {
      result.assign(path.data());
    }

    return result;
  }

  ListeningPorts ProcessInspector::listeningPorts(pid_t group) const noexcept { // NOLINT(readability-convert-member-functions-to-static): the Linux definition reads the sockets of the inspector's user
    constexpr std::size_t maximum_group_processes = 64;
    // Listening sockets open early; a busy server's later descriptors past this bound are connections.
    constexpr std::size_t maximum_descriptors = 1024;
    ListeningPorts ports;
    ds::Array<pid_t, maximum_group_processes> members{};
    ds::Array<proc_fdinfo, maximum_descriptors> descriptors; // NOLINT(cppcoreguidelines-pro-type-member-init): proc_pidinfo writes the descriptors it reports, and only those are read, so zeroing 8 KiB per process is work no read needs

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
        if (socket.soi_kind != SOCKINFO_TCP) {
          continue;
        }

        const auto& tcp = socket.soi_proto.pri_tcp; // NOLINT(cppcoreguidelines-pro-type-union-access): socket_fdinfo reports each protocol's details in a union, which soi_kind selects
        if (tcp.tcpsi_state == TSI_S_LISTEN) {
          ports.add(ntohs(static_cast<std::uint16_t>(tcp.tcpsi_ini.insi_lport)));
        }
      }
    }

    return ports;
  }

  std::size_t ProcessInspector::groupMembers(pid_t group, std::span<pid_t> members) noexcept {
    const auto bytes = ::proc_listpids(PROC_PGRP_ONLY, static_cast<std::uint32_t>(group), members.data(), static_cast<int>(members.size_bytes()));

    return bytes > 0 ? std::min(members.size(), static_cast<std::size_t>(bytes) / sizeof(pid_t)) : 0;
  }

  FixedText<process_path_bytes> ProcessInspector::terminal(pid_t process) const noexcept { // NOLINT(readability-convert-member-functions-to-static,bugprone-exception-escape): the Linux definition is const too, and both share one declaration; assign throws only past its capacity, which a device's path never reaches
    constexpr std::size_t device_name_bytes = 128;
    constexpr std::string_view device_directory = "/dev/";
    FixedText<process_path_bytes> result;
    proc_bsdinfo information{};
    ds::Array<char, device_name_bytes> name{};
    if (::proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &information, sizeof(information)) == sizeof(information) && ::devname_r(static_cast<dev_t>(information.e_tdev), S_IFCHR, name.dataMut(), name.size()) != nullptr) {
      ds::Array<char, device_directory.size() + device_name_bytes> path{};
      const auto device = fieldText(name.view());

      std::ranges::copy(device_directory, path.viewMut().begin());
      std::ranges::copy(device, path.viewMut().subspan(device_directory.size()).begin());
      result.assign(fieldText(path.view()));
    }

    return result;
  }

}
