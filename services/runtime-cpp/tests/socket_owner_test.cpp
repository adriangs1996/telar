#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <optional>
#include <sys/socket.h>
#include <string_view>
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <cstddef>
#include <charconv>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <span>
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>
#include <limits>
#include "telar_base/text/utf8.hpp"
#include <sys/types.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#include <cerrno>
#endif
#if (!(defined(__APPLE__)))
#include <exception>
#endif
#if (!(defined(__APPLE__)))
#include "telar_platform/file_descriptor.hpp"
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <fcntl.h>
#endif
#if (!(defined(__APPLE__)))
#include <dirent.h>
#endif
#if (!(defined(__APPLE__)))
#include <cstdio>
#endif
#include <csignal>
#include <bit>
#include "telar_base/memory/allocator.hpp"
#include <utility>
#include "telar_platform/file_descriptor.hpp"
#include <poll.h>
#include <sys/stat.h>
#include <sys/un.h>
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <net/if.h>
#endif
#if (defined(__APPLE__))
#include <net/if_utun.h>
#endif
#if (defined(__APPLE__))
#include <netinet6/in6_var.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__))
#include <sys/kern_control.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <sys/sys_domain.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (!(defined(__APPLE__)))
#include <net/if.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/uio.h>
#endif
#include <memory>
#include <pcap/pcap.h>
#include <sys/ioctl.h>
#include <stdexcept>
#include <ifaddrs.h>
#include <net/if.h>
#include <fcntl.h>
#include <limits.h>
#include "telar_platform/random_bytes.hpp"
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <cerrno>
#include <cstdlib>
#include <sys/file.h>
#include <thread>
#include <sys/sockio.h>
#include <netinet/tcp.h>
#include "telar_base/program_identity.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <net/if_dl.h>
#include <net/route.h>
#include <exception>
#include <sys/uio.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp_fsm.h>
#include <netinet/tcp_var.h>
#include <sys/socketvar.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <vector>



import telar.runtime.redirect.socket_owners;
import telar.runtime.redirect.pf_rules;

using namespace telar;
using namespace telar::runtime;
namespace redirect = telar::runtime::redirect;

static void receive(int descriptor, std::span<std::uint8_t> bytes) {
  while (!bytes.empty()) {
    pollfd ready{descriptor, POLLIN, 0};
    check(::poll(&ready, 1, 5000) > 0);
    const auto count = ::read(descriptor, bytes.data(), bytes.size());
    check(count > 0);
    bytes = bytes.subspan(count);
  }
}

static void socketOwner(bool ipv6) {
  const auto endpoint = redirect::Target::parse(ipv6 ? "[::1]:1" : "127.0.0.1:1");
  redirect::Listener listener{endpoint};
  auto target = endpoint;
  target.port = listener.mapping().listener_port;
  target.endpoint.setPort(target.port);
  std::array<int, 2> control, result;
  check(::pipe(control.data()) == 0 && ::pipe(result.data()) == 0);
  FileDescriptor stop_read{control[0]}, stop_write{control[1]}, result_read{result[0]}, result_write{result[1]};
  const auto pid = ::fork();
  check(pid >= 0);
  if (pid == 0) {
    ::close(stop_write.get());
    ::close(result_read.get());
    const auto socket = ::socket(target.endpoint.storage.ss_family, SOCK_STREAM, IPPROTO_TCP);
    if (socket < 0 || ::connect(socket, target.endpoint.address(), target.endpoint.length) != 0) { ::_exit(2); }
    sockaddr_storage local{};
    socklen_t size = sizeof(local);
    if (::getsockname(socket, reinterpret_cast<sockaddr *>(&local), &size) != 0) { ::_exit(3); }
    const auto port = ntohs(ipv6 ? reinterpret_cast<sockaddr_in6 *>(&local)->sin6_port : reinterpret_cast<sockaddr_in *>(&local)->sin_port);
    if (::write(result_write.get(), &port, sizeof(port)) != sizeof(port)) { ::_exit(4); }
    std::uint8_t byte;
    ::read(stop_read.get(), &byte, sizeof(byte));
    ::_exit(0);
  }
  stop_read = FileDescriptor{};
  result_write = FileDescriptor{};
  std::uint16_t port;
  receive(result_read.get(), {reinterpret_cast<std::uint8_t *>(&port), sizeof(port)});
  pollfd ready{listener.descriptor(), POLLIN, 0};
  check(::poll(&ready, 1, 5000) > 0);
  const auto peer = listener.accept();
  check(static_cast<bool>(peer));
  SystemAllocator memory;
  redirect::SocketAccounts accounts{memory};
  accounts.validate();
  check(accounts.peer(peer.get()) == ::geteuid());
  redirect::FlowKey flow{.source = endpoint, .destination = target};
  flow.source.port = port;
  flow.source.endpoint.setPort(port);
  const std::array selected{ProcessIdentity{.pid = pid}};
  redirect::SocketOwners owner{::geteuid(), selected};
  const auto identified = owner.find(flow);
  check(identified.complete && identified.process && identified.process->pid == pid);
  const auto pinned = owner.processes()[0];
  check(pinned.started_seconds != 0 && pinned.sameInstance(*identified.process));
  const auto token = redirect::ProcessToken::format(pinned);
  check(redirect::ProcessToken::parse(token.view()).sameInstance(pinned));
  const std::array parent{ProcessIdentity{.pid = ::getpid()}};
  redirect::SocketOwners unselected{::geteuid(), parent};
  const auto excluded = unselected.find(flow);
  check(excluded.complete && !excluded.process);
  auto other_flow = flow;
  other_flow.destination.port = target.port == UINT16_MAX ? 1 : target.port + 1;
  other_flow.destination.endpoint.setPort(other_flow.destination.port);
  check(!owner.find(other_flow).process);
  auto stale = pinned;
  ++stale.started_seconds;
  bool replaced = false;
  try { const std::array requested{stale}; redirect::SocketOwners invalid{::geteuid(), requested}; }
  catch (const std::invalid_argument &) { replaced = true; }
  check(replaced);
  bool other_account = false;
  try { redirect::SocketOwners invalid{static_cast<uid_t>(::geteuid() == 0 ? 1 : 0), selected}; }
  catch (const std::invalid_argument &) { other_account = true; }
  check(other_account);
  stop_write = FileDescriptor{};
  int status = 0;
  check(::waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  check(!owner.find(flow).process);
}

static void accountSnapshot(bool ipv6) {
  const auto origin = redirect::Target::parse(ipv6 ? "[::2]:50000" : "127.0.0.2:50000");
  const auto server = redirect::Target::parse(ipv6 ? "[::1]:443" : "127.0.0.1:443");
  xinpgen header{};
  header.xig_len = sizeof(header);
  header.xig_count = 2;
  xtcpcb64 peer{};
  peer.xt_len = sizeof(peer);
  peer.t_state = TCPS_SYN_RECEIVED;
  auto &pcb = peer.xt_inpcb;
  pcb.xi_len = 0;
  pcb.inp_vflag = ipv6 ? INP_IPV6 : INP_IPV4;
  pcb.inp_lport = htons(server.port);
  pcb.inp_fport = htons(origin.port);
  if (ipv6) {
    pcb.inp_dependladdr.inp6_local = reinterpret_cast<const sockaddr_in6 &>(server.endpoint.storage).sin6_addr;
    pcb.inp_dependfaddr.inp6_foreign = reinterpret_cast<const sockaddr_in6 &>(origin.endpoint.storage).sin6_addr;
  } else {
    pcb.inp_laddr = reinterpret_cast<const sockaddr_in &>(server.endpoint.storage).sin_addr;
    pcb.inp_faddr = reinterpret_cast<const sockaddr_in &>(origin.endpoint.storage).sin_addr;
  }
  pcb.xi_socket.xso_len = sizeof(xsocket64);
  pcb.xi_socket.xso_protocol = IPPROTO_TCP;
  pcb.xi_socket.so_type = SOCK_STREAM;
  pcb.xi_socket.so_uid = 501;
  auto client = peer;
  std::swap(client.xt_inpcb.inp_lport, client.xt_inpcb.inp_fport);
  if (ipv6) { std::swap(client.xt_inpcb.inp_dependladdr.inp6_local, client.xt_inpcb.inp_dependfaddr.inp6_foreign); }
  else { std::swap(client.xt_inpcb.inp_laddr, client.xt_inpcb.inp_faddr); }
  client.xt_inpcb.xi_socket.so_uid = 0;
  std::vector<std::uint8_t> bytes(2 * sizeof(header) + 2 * sizeof(peer));
  std::memcpy(bytes.data(), &header, sizeof(header));
  std::memcpy(bytes.data() + sizeof(header), &client, sizeof(client));
  std::memcpy(bytes.data() + sizeof(header) + sizeof(client), &peer, sizeof(peer));
  std::memcpy(bytes.data() + bytes.size() - sizeof(header), &header, sizeof(header));
  using Accounts = redirect::SocketAccounts<SystemAllocator>;
  check(Accounts::decode(bytes, origin.endpoint.storage, server.endpoint.storage) == 501);
  check(Accounts::decode(bytes, server.endpoint.storage, origin.endpoint.storage) == 0);
  auto other = server;
  other.endpoint.setPort(444);
  check(!Accounts::decode(bytes, origin.endpoint.storage, other.endpoint.storage));
  bool truncated = false;
  try { Accounts::decode(std::span{bytes}.first(bytes.size() - 1), origin.endpoint.storage, server.endpoint.storage); }
  catch (const telar::EncodingError &) { truncated = true; }
  check(truncated);
}

int main() {
  accountSnapshot(false);
  accountSnapshot(true);
  socketOwner(false);
  socketOwner(true);
  const redirect::LocalAddresses addresses;
  check(!addresses.contains(redirect::Target::parse("127.0.0.1:443")) && !addresses.contains(redirect::Target::parse("[::1]:443")));
  bool rejected_local = false;
  try { const std::array targets{redirect::Target::parse("127.0.0.1:443")}; redirect::LocalAddresses::selection(targets, redirect::Direction::inbound); }
  catch (const std::invalid_argument &) { rejected_local = true; }
  check(rejected_local);
  for (const auto name : {"127.0.0.1:443", "[::1]:443"}) {
    const auto route = redirect::RoutePath::lookup(redirect::Target::parse(name));
    check(route.interface.view() == "lo0" && route.index == ::if_nametoindex("lo0"));
    const auto scoped = redirect::RoutePath::lookup(redirect::Target::parse(name), route.index);
    check(scoped.index == route.index && scoped.gateway.view() == route.gateway.view());
  }
  std::puts("Socket ownership: real child TCP sockets, IPv4/IPv6, four-tuples, account boundaries, exit and stale process identities verified");
}
