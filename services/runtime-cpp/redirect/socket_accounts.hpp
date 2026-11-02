#pragma once

#include "target.hpp"
#include "../memory/sensitive_allocation.hpp"
#include "../platform/error.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <sys/socketvar.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp.h>
#include <netinet/tcp_var.h>
#include <netinet/tcp_fsm.h>
#include <sys/sysctl.h>
#include <poll.h>

namespace telar::runtime::redirect {

template <Allocator Memory>
class SocketAccounts {
public:
  explicit SocketAccounts(Memory &memory) noexcept : memory_(memory) {}

  void validate() {
    refresh();
    decode(snapshot_->bytes().first(size_), {}, {});
  }

  std::optional<uid_t> peer(int descriptor) {
    sockaddr_storage local{}, remote{};
    socklen_t length = sizeof(local);
    if (::getsockname(descriptor, reinterpret_cast<sockaddr *>(&local), &length) != 0) { throw SystemError{"Read origin socket identity"}; }
    length = sizeof(remote);
    if (::getpeername(descriptor, reinterpret_cast<sockaddr *>(&remote), &length) != 0) { throw SystemError{"Read origin peer identity"}; }
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
      refresh();
      if (const auto account = decode(snapshot_->bytes().first(size_), local, remote)) { return account; }
      if (attempt != 2) { ::poll(nullptr, 0, 1); }
    }
    return {};
  }

  static std::optional<uid_t> decode(std::span<const Byte> bytes, const sockaddr_storage &local, const sockaddr_storage &peer) {
    if (bytes.size() < sizeof(xinpgen)) { throw EncodingError{"Incomplete TCP account snapshot"}; }
    xinpgen header;
    std::memcpy(&header, bytes.data(), sizeof(header));
    if (header.xig_len != sizeof(header)) { throw EncodingError{"Unsupported TCP account snapshot header"}; }
    if (bytes.size() == sizeof(header) && header.xig_count == 0) { return {}; }
    if (bytes.size() < 2 * sizeof(header)) { throw EncodingError{"Incomplete TCP account snapshot"}; }
    bytes = bytes.subspan(sizeof(header));
    std::optional<uid_t> account;
    while (bytes.size() > sizeof(xinpgen)) {
      std::uint32_t length;
      std::memcpy(&length, bytes.data(), sizeof(length));
      if (length != sizeof(xtcpcb64) || length > bytes.size() - sizeof(xinpgen)) { throw EncodingError{"Unsupported TCP account record"}; }
      xtcpcb64 entry;
      std::memcpy(&entry, bytes.data(), sizeof(entry));
      const auto &socket = entry.xt_inpcb.xi_socket;
      // Darwin's conversion leaves xi_len zero; the outer TCP record bounds
      // and the socket's own length still identify the supported SDK layout.
      if ((entry.xt_inpcb.xi_len != 0 && entry.xt_inpcb.xi_len != sizeof(xinpcb64)) || (socket.xso_protocol == IPPROTO_TCP && socket.xso_len != sizeof(xsocket64))) { throw EncodingError{"Unsupported TCP socket account layout"}; }
      if (entry.t_state >= TCPS_SYN_RECEIVED && socket.so_type == SOCK_STREAM && socket.xso_protocol == IPPROTO_TCP && matches(entry.xt_inpcb, local, peer)) {
        if (account && *account != socket.so_uid) { throw EncodingError{"Ambiguous TCP peer account"}; }
        account = socket.so_uid;
      }
      bytes = bytes.subspan(length);
    }
    if (bytes.size() != sizeof(xinpgen)) { throw EncodingError{"Incomplete TCP account snapshot footer"}; }
    std::memcpy(&header, bytes.data(), sizeof(header));
    if (header.xig_len != sizeof(header)) { throw EncodingError{"Unsupported TCP account snapshot footer"}; }
    return account;
  }

private:
  void refresh() {
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
      std::size_t needed = 0;
      if (::sysctlbyname("net.inet.tcp.pcblist64", nullptr, &needed, nullptr, 0) != 0) { throw SystemError{"Query TCP account snapshot"}; }
      if (needed < 2 * sizeof(xinpgen) || needed > maximum_bytes) { throw SystemError{"TCP account snapshot exceeds its bound", ENOSPC}; }
      if (!snapshot_ || snapshot_->bytes().size() < needed) { snapshot_.emplace(memory_, std::min(maximum_bytes, needed + needed / 4 + sizeof(xtcpcb64))); }
      size_ = snapshot_->bytes().size();
      if (::sysctlbyname("net.inet.tcp.pcblist64", snapshot_->bytes().data(), &size_, nullptr, 0) == 0) { return; }
      if (errno != ENOMEM && errno != EINTR) { throw SystemError{"Read TCP account snapshot"}; }
    }
    throw SystemError{"TCP account snapshot changed repeatedly", EAGAIN};
  }

  static bool matches(const xinpcb64 &pcb, const sockaddr_storage &local, const sockaddr_storage &peer) noexcept {
    if (local.ss_family != peer.ss_family) { return false; }
    if (local.ss_family == AF_INET && (pcb.inp_vflag & INP_IPV4)) {
      const auto &origin = reinterpret_cast<const sockaddr_in &>(local);
      const auto &server = reinterpret_cast<const sockaddr_in &>(peer);
      return pcb.inp_lport == server.sin_port && pcb.inp_fport == origin.sin_port && pcb.inp_laddr.s_addr == server.sin_addr.s_addr && pcb.inp_faddr.s_addr == origin.sin_addr.s_addr;
    }
    if (local.ss_family == AF_INET6 && (pcb.inp_vflag & INP_IPV6)) {
      const auto &origin = reinterpret_cast<const sockaddr_in6 &>(local);
      const auto &server = reinterpret_cast<const sockaddr_in6 &>(peer);
      return pcb.inp_lport == server.sin6_port && pcb.inp_fport == origin.sin6_port && std::memcmp(&pcb.inp_dependladdr.inp6_local, &server.sin6_addr, sizeof(in6_addr)) == 0 && std::memcmp(&pcb.inp_dependfaddr.inp6_foreign, &origin.sin6_addr, sizeof(in6_addr)) == 0;
    }
    return false;
  }

  static constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;
  Memory &memory_;
  std::optional<SensitiveAllocation<Memory>> snapshot_;
  std::size_t size_ = 0;
};

}
