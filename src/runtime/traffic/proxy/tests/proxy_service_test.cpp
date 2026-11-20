#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <nghttp2/nghttp2.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>
#include <zstd.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <poll.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif

import std;
import telar.base.text;
import telar.platform.primitives;
import telar.tls.tests.tls_fixture;
import telar.runtime.traffic.proxy.runtime;
import telar.testing;
import telar.config.runtime;
import telar.platform.net;
import telar.runtime.traffic.http2.direction_observer;
import telar.runtime.traffic.http2.frame_reader;
import telar.runtime.host.event_loop;
import telar.runtime.host.name_resolutions;
import telar.runtime.traffic.proxy.authenticate;
import telar.runtime.traffic.proxy.http2_capture_streams;
import telar.runtime.traffic.tls.interception;
import telar.runtime.traffic.tap.exchange;
import telar.tls;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  class ServiceResolver {
  public:
    static ResolutionSummary resolve(const char* /*hostname*/, std::span<NetworkAddress> addresses) noexcept {
      sockaddr_in loopback{};

#if defined(__APPLE__)
      loopback.sin_len = sizeof(loopback);
#endif
      loopback.sin_family = AF_INET;
      loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      addresses[0] = *NetworkAddress::copy(reinterpret_cast<const sockaddr*>(&loopback), sizeof(loopback));
      return {.found = 1};
    }
  };

  // Fails at the caller's line, which names what never became ready.
  template <typename Predicate>
  void await(Predicate ready, std::source_location location = std::source_location::current()) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline, "not ready within 5 s", location);
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }

  FileDescriptor connectLocal(std::uint16_t port) {
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};

    check(static_cast<bool>(socket));
    sockaddr_in address{};

#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(::connect(socket.get(), reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    configureProxySocket(socket.get());
    return socket;
  }

  std::string request(const ProxySecret& secret, std::uint16_t port, std::string_view hostname) {
    ds::Array<char, ProxySecret::hexadecimal_bytes> hexadecimal;
    const auto user = "telar:" + std::string{*secret.formatHexadecimal(hexadecimal.viewMut())};
    ds::Array<char, 128> encoded;
    const auto count = base64::encode({reinterpret_cast<const std::uint8_t*>(user.data()), user.size()}, encoded.viewMut());

    check(count.hasValue());
    return "CONNECT " + std::string{hostname} + ":" + std::to_string(port) + " HTTP/1.1\r\nProxy-Authorization: Basic " + std::string{encoded.data(), *count} + "\r\n\r\n";
  }

  void writeText(int socket, std::string_view text) {
    check(::send(socket, text.data(), text.size(), 0) == static_cast<ssize_t>(text.size()));
  }

  std::string readHead(int socket) {
    std::string head;

    await([&] {
      ds::Array<char, 4096> bytes;
      const auto read = ::recv(socket, bytes.dataMut(), bytes.size(), 0);

      check(read > 0 || (read < 0 && socketWouldBlock(errno)));
      if (read > 0) {
        head.append(bytes.data(), static_cast<std::size_t>(read));
      }

      return head.ends_with("\r\n\r\n");
    });

    return head;
  }

  // Silent sockets that fill every unauthenticated slot cannot lock legitimate clients out: once the
  // oldest has waited past the eviction age, a newcomer takes its place and is served.
  void testUnauthenticatedEviction(TlsTestMemory& memory, const TlsLibrary& library) {
    TlsTrustStore trust{memory, library};
    TlsContexts contexts{memory, library, trust};
    TlsInterception interception{contexts, nullptr};
    ProxyOptions options{memory};
    const auto secret = ProxySecret::generate();
    auto origin_listener = ProxyListener::bind(ds::none, {});
    ProxyService<NativeEventLoop<TlsTestMemory>, ServiceResolver> service{memory, ProxyServiceParts{.options = options, .secret = secret, .interception = interception}, ProxyListener::bind(ds::none, {})};
    ds::Array<FileDescriptor, ProxyConnectionPolicy::maximum_unauthenticated> silent;

    silent.atMut(0) = connectLocal(service.port());
    await([&] {
      return service.active() == 1;
    });

    for (auto& socket : silent.viewMut().subspan(1)) {
      socket = connectLocal(service.port());
    }

    await([&] {
      return service.active() == silent.size();
    });

    std::this_thread::sleep_for(ProxyConnectionPolicy::evictable_head_age + std::chrono::milliseconds{100});
    auto newcomer = connectLocal(service.port());

    writeText(newcomer.get(), request(secret, origin_listener.port(), "origin.test"));
    check(readHead(newcomer.get()) == "HTTP/1.1 200 Connection Established\r\n\r\n");
    await([&] {
      char byte;

      return ::recv(silent.front().get(), &byte, 1, 0) == 0;
    });

    check(service.counters().read(ProxyCounter::unauthenticated_eviction) == 1);
  }

  const telar::testing::Case case_unauthenticated_eviction{"proxy_service.unauthenticated_eviction", withTlsLibrary<testUnauthenticatedEviction>};

}
