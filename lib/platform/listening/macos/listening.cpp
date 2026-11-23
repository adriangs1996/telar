module telar.platform.listening;

import telar.base.ds;
import telar.sys.apple;
import telar.sys.socket;

namespace telar::runtime {

  std::size_t processListeningPorts(pid_t process, std::span<std::uint16_t> ports) noexcept {
    // Listening sockets open early; a busy server's later descriptors past this bound are connections.
    constexpr std::size_t maximum_descriptors = 1024;
    ds::Array<proc_fdinfo, maximum_descriptors> descriptors; // NOLINT(cppcoreguidelines-pro-type-member-init): proc_pidinfo writes the descriptors it reports, and only those are read, so zeroing 8 KiB per process is work no read needs
    const auto bytes = ::proc_pidinfo(process, PROC_PIDLISTFDS, 0, descriptors.dataMut(), static_cast<int>(sizeof(descriptors)));
    std::size_t count = 0;

    if (bytes <= 0) {
      return 0;
    }

    for (const auto& descriptor : std::span{descriptors}.first(std::min(descriptors.size(), static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo)))) {
      if (count == ports.size()) {
        break;
      }

      if (descriptor.proc_fdtype != PROX_FDTYPE_SOCKET) {
        continue;
      }

      socket_fdinfo information{};
      if (::proc_pidfdinfo(process, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, sizeof(information)) != sizeof(information)) {
        continue;
      }

      const auto& socket = information.psi;
      if (socket.soi_kind != SOCKINFO_TCP) {
        continue;
      }

      const auto& tcp = socket.soi_proto.pri_tcp; // NOLINT(cppcoreguidelines-pro-type-union-access): socket_fdinfo reports each protocol's details in a union, which soi_kind selects
      if (tcp.tcpsi_state == TSI_S_LISTEN) {
        ports[count++] = ntohs(static_cast<std::uint16_t>(tcp.tcpsi_ini.insi_lport));
      }
    }

    return count;
  }

  std::size_t processGroupMembers(pid_t group, std::span<pid_t> members) noexcept {
    const auto bytes = ::proc_listpids(PROC_PGRP_ONLY, static_cast<std::uint32_t>(group), members.data(), static_cast<int>(members.size_bytes()));

    return bytes > 0 ? std::min(members.size(), static_cast<std::size_t>(bytes) / sizeof(pid_t)) : 0;
  }

  std::size_t groupListeningPorts(uid_t /*user*/, pid_t group, std::span<std::uint16_t> ports) noexcept {
    constexpr std::size_t maximum_group_processes = 64;
    ds::Array<pid_t, maximum_group_processes> members{};
    std::size_t count = 0;

    for (const auto member : std::span{members}.first(processGroupMembers(group, members.viewMut()))) {
      count += processListeningPorts(member, ports.subspan(count));
    }

    return count;
  }

  std::size_t userListeningPorts(uid_t user, std::span<std::uint16_t> ports) noexcept {
    constexpr std::size_t maximum_processes = 4096;
    constexpr std::size_t maximum_sockets = 512;
    ds::Array<pid_t, maximum_processes> processes; // NOLINT(cppcoreguidelines-pro-type-member-init): proc_listpids writes the processes it reports, and only those are read
    ds::Array<std::uint16_t, maximum_sockets> found{};
    const auto bytes = ::proc_listpids(PROC_UID_ONLY, static_cast<std::uint32_t>(user), processes.dataMut(), static_cast<int>(sizeof(processes)));
    std::size_t listening = 0;

    if (bytes <= 0) {
      return 0;
    }

    for (const auto process : std::span{processes}.first(std::min(processes.size(), static_cast<std::size_t>(bytes) / sizeof(pid_t)))) {
      listening += processListeningPorts(process, found.viewMut().subspan(listening));
    }

    const auto sorted = found.viewMut().first(listening);

    // A port two processes or two address families listen on is told once.
    std::ranges::sort(sorted);
    const auto distinct = std::ranges::unique(sorted);
    const auto count = std::min(ports.size(), static_cast<std::size_t>(distinct.begin() - sorted.begin()));

    std::ranges::copy(sorted.first(count), ports.begin());
    return count;
  }

}
