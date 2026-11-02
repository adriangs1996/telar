#pragma once

#include "flow_key.hpp"
#include "../platform/process_inspector.hpp"
#include <libproc.h>

namespace telar::runtime::redirect {

class SocketOwners {
public:
  static constexpr std::size_t maximum_processes = 16;
  static constexpr std::size_t maximum_descriptors = 4096;

  struct Result {
    std::optional<ProcessIdentity> process;
    bool complete = true;
  };

  explicit SocketOwners(uid_t uid, std::span<const ProcessIdentity> selected) : inspector_(builtin_manifests, uid) {
    if (selected.size() > maximum_processes) { throw std::invalid_argument{"Too many selected processes"}; }
    for (const auto &requested : selected) {
      const auto current = inspector_.identity(requested.pid);
      if (!current || (requested.started_seconds != 0 && !current->sameInstance(requested))) { throw std::invalid_argument{"Selected process is unavailable, replaced or belongs to another account"}; }
      if (std::ranges::any_of(std::span{processes_}.first(count_), [&](const auto &other) { return other.pid == current->pid; })) { throw std::invalid_argument{"Duplicate selected process"}; }
      processes_[count_++] = *current;
    }
  }

  bool enabled() const noexcept { return count_ != 0; }
  std::span<const ProcessIdentity> processes() const noexcept { return std::span{processes_}.first(count_); }

  Result find(const FlowKey &flow) noexcept {
    Result result;
    for (const auto &selected : processes()) {
      const auto current = inspector_.identity(selected.pid);
      if (!current || !current->sameInstance(selected)) { continue; }
      const auto bytes = ::proc_pidinfo(selected.pid, PROC_PIDLISTFDS, 0, descriptors_.data(), sizeof(descriptors_));
      if (bytes <= 0 || bytes >= static_cast<int>(sizeof(descriptors_)) || bytes % sizeof(proc_fdinfo) != 0) { result.complete = false; continue; }
      const auto count = static_cast<std::size_t>(bytes) / sizeof(proc_fdinfo);
      for (const auto &descriptor : std::span{descriptors_}.first(count)) {
        if (descriptor.proc_fdtype != PROX_FDTYPE_SOCKET) { continue; }
        socket_fdinfo information{};
        if (::proc_pidfdinfo(selected.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, sizeof(information)) != sizeof(information)) { if (errno != EBADF && errno != ESRCH) { result.complete = false; } continue; }
        const auto &socket = information.psi;
        if (socket.soi_kind != SOCKINFO_TCP || socket.soi_type != SOCK_STREAM || socket.soi_protocol != IPPROTO_TCP) { continue; }
        const auto &tcp = socket.soi_proto.pri_tcp;
        if (tcp.tcpsi_state == TSI_S_CLOSED || tcp.tcpsi_state == TSI_S_LISTEN || !matches(tcp.tcpsi_ini, flow)) { continue; }
        const auto verified = inspector_.identity(selected.pid);
        if (verified && verified->sameInstance(selected)) { result.process = *verified; result.complete = true; return result; }
      }
    }
    return result;
  }

private:
  static bool matches(const in_sockinfo &socket, const FlowKey &flow) noexcept {
    if (ntohs(static_cast<std::uint16_t>(socket.insi_lport)) != flow.source.port || ntohs(static_cast<std::uint16_t>(socket.insi_fport)) != flow.destination.port) { return false; }
    const auto family = flow.source.endpoint.storage.ss_family;
    if (family != flow.destination.endpoint.storage.ss_family) { return false; }
    if (family == AF_INET && (socket.insi_vflag & INI_IPV4)) {
      const auto &local = reinterpret_cast<const sockaddr_in &>(flow.source.endpoint.storage).sin_addr;
      const auto &remote = reinterpret_cast<const sockaddr_in &>(flow.destination.endpoint.storage).sin_addr;
      return socket.insi_laddr.ina_46.i46a_addr4.s_addr == local.s_addr && socket.insi_faddr.ina_46.i46a_addr4.s_addr == remote.s_addr;
    }
    if (family == AF_INET6 && (socket.insi_vflag & INI_IPV6)) {
      const auto &local = reinterpret_cast<const sockaddr_in6 &>(flow.source.endpoint.storage).sin6_addr;
      const auto &remote = reinterpret_cast<const sockaddr_in6 &>(flow.destination.endpoint.storage).sin6_addr;
      return std::memcmp(&socket.insi_laddr.ina_6, &local, sizeof(local)) == 0 && std::memcmp(&socket.insi_faddr.ina_6, &remote, sizeof(remote)) == 0;
    }
    return false;
  }

  ProcessInspector inspector_;
  std::array<ProcessIdentity, maximum_processes> processes_;
  std::size_t count_ = 0;
  std::array<proc_fdinfo, maximum_descriptors> descriptors_;
};

}
