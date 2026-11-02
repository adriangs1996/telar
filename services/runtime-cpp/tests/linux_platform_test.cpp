#include "check.hpp"
#include "platform/linux/proc_file.hpp"
#include "platform/process_inspector.hpp"
#include "platform/system_certificates.hpp"
#include "redirect/socket_owners.hpp"
#include <algorithm>
#include <sys/prctl.h>

using namespace telar::runtime;

namespace {

void processIdentity() {
  ProcessInspector inspector;
  const auto identity = inspector.identity(::getpid());
  check(identity && identity->parent == ::getppid() && identity->process_group == ::getpgrp());
  check(inspector.directory(::getpid()).view().starts_with('/'));
  ProcessInspector foreign{builtin_manifests, static_cast<uid_t>(::geteuid() + 1)};
  check(!foreign.identity(::getpid()));

  int descriptors[2];
  check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
  const FileDescriptor first{descriptors[0]};
  const FileDescriptor second{descriptors[1]};
  check(inspector.peer(first.get()) == identity);
  const auto original_name = inspector.name(::getpid());
  constexpr std::string_view unusual_name = "a ) b ( c";
  check(::prctl(PR_SET_NAME, unusual_name.data()) == 0);
  check(inspector.name(::getpid()).view() == unusual_name);
  check(inspector.identity(::getpid()) == identity);
  std::array<char, 16> restored_name{};
  std::ranges::copy(original_name.view(), restored_name.begin());
  check(::prctl(PR_SET_NAME, restored_name.data()) == 0);
  check(!ProcStat::parse("1 (broken)"));
}

redirect::Target socketEndpoint(int descriptor, bool peer) {
  sockaddr_storage address{};
  socklen_t length = sizeof(address);
  check((peer ? ::getpeername(descriptor, reinterpret_cast<sockaddr *>(&address), &length) : ::getsockname(descriptor, reinterpret_cast<sockaddr *>(&address), &length)) == 0);
  redirect::Target target;
  target.endpoint = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&address), length);
  std::array<char, INET6_ADDRSTRLEN> host{};
  if (address.ss_family == AF_INET) {
    const auto &v4 = reinterpret_cast<const sockaddr_in &>(address);
    check(::inet_ntop(AF_INET, &v4.sin_addr, host.data(), host.size()) != nullptr);
    target.port = ntohs(v4.sin_port);
  } else {
    const auto &v6 = reinterpret_cast<const sockaddr_in6 &>(address);
    check(::inet_ntop(AF_INET6, &v6.sin6_addr, host.data(), host.size()) != nullptr);
    target.port = ntohs(v6.sin6_port);
  }
  target.endpoint.setPort(target.port);
  target.host.assign(host.data());
  return target;
}

void socketOwnership(int family) {
  FileDescriptor listener{::socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0)};
  check(static_cast<bool>(listener));
  auto destination = redirect::Target::parse(family == AF_INET ? "127.0.0.1:1" : "[::1]:1");
  destination.endpoint.setPort(0);
  check(::bind(listener.get(), destination.endpoint.address(), destination.endpoint.length) == 0);
  check(::listen(listener.get(), 1) == 0);
  destination = socketEndpoint(listener.get(), false);

  FileDescriptor client{::socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0)};
  check(static_cast<bool>(client));
  check(::connect(client.get(), destination.endpoint.address(), destination.endpoint.length) == 0);
  const FileDescriptor accepted{::accept4(listener.get(), nullptr, nullptr, SOCK_CLOEXEC)};
  check(static_cast<bool>(accepted));
  const redirect::FlowKey flow{socketEndpoint(client.get(), false), socketEndpoint(client.get(), true)};
  const auto identity = ProcessInspector{}.identity(::getpid());
  check(identity.has_value());
  const std::array selected{*identity};
  redirect::SocketOwners owners{::geteuid(), selected};
  const auto owner = owners.find(flow);
  check(owner.complete && owner.process == identity);

  bool found_account = false;
  redirect::visitLinuxTcpSockets([&](const redirect::LinuxTcpSocket &socket) {
    if (socket.matches(flow.source, flow.destination)) {
      check(socket.user == ::geteuid() && socket.inode != 0);
      found_account = true;
    }
    return true;
  });
  check(found_account);
}

void systemCertificates() {
  std::size_t count = 0;
  SystemCertificates::read([&](std::span<const std::uint8_t> certificate) {
    const auto *encoded = certificate.data();
    const std::unique_ptr<X509, decltype(&X509_free)> parsed{d2i_X509(nullptr, &encoded, certificate.size()), &X509_free};
    check(static_cast<bool>(parsed) && encoded == certificate.data() + certificate.size());
    ++count;
  });
  check(count > 0);
}

}

int main() {
  processIdentity();
  socketOwnership(AF_INET);
  socketOwnership(AF_INET6);
  systemCertificates();
}
