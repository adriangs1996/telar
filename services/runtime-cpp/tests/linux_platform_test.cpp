#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <limits>
#include <optional>
#include <span>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include "telar_base/text/utf8.hpp"
#include <cstring>
#include <sys/types.h>
#if (defined(__APPLE__))
#include <cerrno>
#endif
#if (defined(__APPLE__))
#include <exception>
#endif
#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#endif
#if (defined(__APPLE__))
#include <memory>
#endif
#if (defined(__APPLE__))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <cstdlib>
#endif
#if (!(defined(__APPLE__)))
#include <memory>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/err.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/pem.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#include <netinet/in.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <cstddef>
#include "telar_client/codecs/telar_wire.hpp"
#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <dirent.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#include <cstdlib>
#include <limits.h>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/trace.hpp"
#include <exception>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <ctime>
#include <string>
#include <sys/prctl.h>



import telar.runtime.platform.launch_program;
import telar.runtime.platform.process_probe;
import telar.runtime.platform.system_certificates;
import telar.runtime.redirect.socket_owners;
import telar.platform;
import telar.tls;

using namespace telar;
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

void restrictedSystemCertificates() {
  TemporaryDirectory directory{"/tmp/telar-system-trust-XXXXXX"};
  const auto path = std::string{directory.path()} + "/roots.pem";
  auto allowed = CertificatePair::authority("Allowed TLS root", CertificatePair::private_lifetime);
  auto rejected = CertificatePair::authority("Rejected TLS root", CertificatePair::private_lifetime);
  auto other_purpose = CertificatePair::authority("Client-only root", CertificatePair::private_lifetime);
  check(X509_add1_reject_object(rejected.certificate.get(), OBJ_nid2obj(NID_server_auth)) == 1);
  check(X509_add1_trust_object(other_purpose.certificate.get(), OBJ_nid2obj(NID_client_auth)) == 1);
  {
    const TlsBuffer file{BIO_new_file(path.c_str(), "w")};
    check(file != nullptr);
    for (auto *certificate : {allowed.certificate.get(), rejected.certificate.get(), other_purpose.certificate.get()}) {
      check(PEM_write_bio_X509_AUX(file.get(), certificate) == 1);
    }
  }

  const auto *variable = X509_get_default_cert_file_env();
  const auto *previous = std::getenv(variable);
  const auto saved = previous ? std::optional{std::string{previous}} : std::nullopt;
  check(::setenv(variable, path.c_str(), 1) == 0);
  std::size_t count = 0;
  SystemCertificates::read([&](std::span<const std::uint8_t> certificate) {
    const auto *bytes = certificate.data();
    const TlsCertificate decoded{d2i_X509(nullptr, &bytes, certificate.size())};
    check(decoded != nullptr && X509_cmp(decoded.get(), allowed.certificate.get()) == 0);
    ++count;
  });
  check(count == 1);
  if (saved) {
    check(::setenv(variable, saved->c_str(), 1) == 0);
  } else {
    check(::unsetenv(variable) == 0);
  }
}

}

int main() {
  processIdentity();
  socketOwnership(AF_INET);
  socketOwnership(AF_INET6);
  systemCertificates();
  restrictedSystemCertificates();
}
