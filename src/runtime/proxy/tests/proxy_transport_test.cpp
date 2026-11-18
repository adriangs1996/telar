#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <fcntl.h>
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
import telar.base.memory.allocators;
import telar.base.text;
import telar.platform.primitives;
import telar.testing;
import telar.testing.test_memory;
import telar.testing.socket_pair;
import telar.testing.test_byte_stream;
import telar.runtime.proxy.http2_capture_streams;
import telar.runtime.proxy.runtime;
import telar.runtime.proxy.relay_direction;
import telar.platform.error;
import telar.config.runtime;
import telar.platform.net;
import telar.runtime.platform.event_loop;
import telar.runtime.platform.name_resolutions;
import telar.runtime.proxy.authenticate;
import telar.runtime.redirect.ingress;
import telar.runtime.tls.tests.hello_fixture;
import telar.runtime.tls.interception;
import telar.tls;
import telar.tls.tests.tls_fixture;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void sendBytes(int socket, std::string_view bytes) {
    check(::send(socket, bytes.data(), bytes.size(), 0) == static_cast<ssize_t>(bytes.size()));
  }

  std::string receiveBytes(int socket) {
    ds::Array<char, 32768> bytes;
    const auto count = ::recv(socket, bytes.dataMut(), bytes.size(), 0);
    if (count < 0 && socketWouldBlock(errno)) {
      return {};
    }

    check(count >= 0);
    return {bytes.data(), static_cast<std::size_t>(count)};
  }

  void testConnectHead() {
    constexpr std::string_view request = "CONNECT localhost:443 HTTP/1.1\r\nProxy-Authorization: fixture\r\n\r\n";
    constexpr std::string_view payload = "tunnel payload\r\n\r\n";

    for (std::size_t boundary = 0; boundary <= request.size(); ++boundary) {
      SocketPair sockets;
      ConnectHead head;

      check(head.receive(sockets.local.get()) == ConnectHead::Read::pending);
      if (boundary != 0) {
        sendBytes(sockets.remote.get(), request.substr(0, boundary));
      }

      check(head.receive(sockets.local.get()) == (boundary == request.size() ? ConnectHead::Read::complete : ConnectHead::Read::pending));
      sendBytes(sockets.remote.get(), std::string{request.substr(boundary)} + std::string{payload});
      check(head.receive(sockets.local.get()) == ConnectHead::Read::complete && head.text() == request);
      check(receiveBytes(sockets.local.get()) == payload);
      head.erase();
      check(head.text().empty());
    }

    for (const bool terminated : {false, true}) {
      SocketPair sockets;
      ConnectHead head;
      auto request = std::string(ConnectHead::capacity, 'a');

      if (terminated) {
        request.replace(request.size() - 4, 4, "\r\n\r\n");
      }

      sendBytes(sockets.remote.get(), request);
      check(head.receive(sockets.local.get()) == (terminated ? ConnectHead::Read::complete : ConnectHead::Read::too_large));
    }

    SocketPair sockets;
    ConnectHead head;

    sendBytes(sockets.remote.get(), "CONNECT localhost");
    check(head.receive(sockets.local.get()) == ConnectHead::Read::pending);
    ::shutdown(sockets.remote.get(), SHUT_WR);
    check(head.receive(sockets.local.get()) == ConnectHead::Read::ended);
  }

  // Moves what one socket holds to another through a relay direction.
  template <typename Direction>
  void relaySockets(Direction& direction, int source, int destination) {
    SocketStream incoming{source};
    SocketStream outgoing{destination};

    direction.advance(incoming, outgoing);
  }

  template <std::size_t Capacity>
  void testRelay() {
    SocketPair child;
    SocketPair origin;
    RelayDirection<Capacity> outbound;
    RelayDirection<Capacity> inbound;
    const int small_buffer = 1024;

    check(::setsockopt(origin.local.get(), SOL_SOCKET, SO_SNDBUF, &small_buffer, sizeof(small_buffer)) == 0);
    constexpr std::size_t payload_bytes = 256 * 1024;
    std::string payload(payload_bytes, '\0');

    for (std::size_t index = 0; index < payload.size(); ++index) {
      payload[index] = static_cast<char>(index * 13);
    }

    std::size_t sent = 0;
    std::string received;
    const auto deadline = ProxyConnectionPolicy::Clock::now() + std::chrono::seconds{5};
    bool half_closed = false;
    bool blocked = false;

    while (!outbound.finished() || received.size() != payload.size()) {
      check(ProxyConnectionPolicy::Clock::now() < deadline);
      if (sent != payload.size()) {
        const auto count = ::send(child.remote.get(), payload.data() + sent, payload.size() - sent, 0);

        check(count >= 0 || socketWouldBlock(errno));
        if (count > 0) {
          sent += static_cast<std::size_t>(count);
        }
      } else if (!half_closed) {
        check(::shutdown(child.remote.get(), SHUT_WR) == 0);
        half_closed = true;
      }

      relaySockets(outbound, child.local.get(), origin.local.get());
      blocked = blocked || outbound.wantsWrite();
      received += receiveBytes(origin.remote.get());
    }

    check(blocked && received == payload && outbound.finished());
    std::uint8_t byte;

    check(::recv(origin.remote.get(), &byte, 1, 0) == 0);

    sendBytes(origin.remote.get(), "reply after request EOF");
    check(::shutdown(origin.remote.get(), SHUT_WR) == 0);
    received.clear();
    while (!inbound.finished()) {
      check(ProxyConnectionPolicy::Clock::now() < deadline);
      relaySockets(inbound, origin.local.get(), child.local.get());
      received += receiveBytes(child.remote.get());
    }

    check(received == "reply after request EOF" && ::recv(child.remote.get(), &byte, 1, 0) == 0);

    SocketPair abandoned;
    SocketPair target;
    RelayDirection<Capacity> broken;

    sendBytes(abandoned.remote.get(), "discard on destination failure");
    target.remote.reset();
    relaySockets(broken, abandoned.local.get(), target.local.get());
    check(broken.finished());
  }

  class LoopbackResolver {
  public:
    static ResolutionSummary resolve(const char*, std::span<NetworkAddress> addresses) noexcept {
      sockaddr_in6 unavailable{};

#if defined(__APPLE__)
      unavailable.sin6_len = sizeof(unavailable);
#endif
      unavailable.sin6_family = AF_INET6;
      unavailable.sin6_addr = in6addr_loopback;
      addresses[0] = *NetworkAddress::copy(reinterpret_cast<const sockaddr*>(&unavailable), sizeof(unavailable));

      sockaddr_in loopback{};

#if defined(__APPLE__)
      loopback.sin_len = sizeof(loopback);
#endif
      loopback.sin_family = AF_INET;
      loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      addresses[1] = *NetworkAddress::copy(reinterpret_cast<const sockaddr*>(&loopback), sizeof(loopback));
      return {.found = 2};
    }
  };

  template <std::size_t Capacity>
  void testDuplexWorkBound() {
    TestByteStream child;
    TestByteStream origin;

    child.input.assign(256 * 1024, 'a');
    origin.input.assign(256 * 1024, 'b');
    DuplexRelay<Capacity> relay;

    check(relay.advance(child, origin, TunnelReadiness::available()));
    check(relay.advance(child, origin, TunnelReadiness::available()));
    check(child.output == origin.input && origin.output == child.input);

    child.ended = true;
    origin.ended = true;
    relay.advance(child, origin, TunnelReadiness::available());
    check(relay.finished() && child.half_closed && origin.half_closed);
  }

  class FailedResolver {
  public:
    static ResolutionSummary resolve(const char*, std::span<NetworkAddress>) noexcept {
      return {.error = EAI_NONAME};
    }
  };

  template <typename Handshake>
  void finishHandshake(Handshake& handshake) {
    const auto deadline = ProxyConnectionPolicy::Clock::now() + std::chrono::seconds{5};

    while (handshake.state() != Handshake::State::closed && handshake.state() != Handshake::State::established) {
      check(ProxyConnectionPolicy::Clock::now() < deadline);
      pollfd origin{.fd = handshake.originDescriptor(), .events = POLLOUT, .revents = 0};

      ::poll(&origin, 1, 1);
      handshake.advance(origin.revents != 0, ProxyConnectionPolicy::Clock::now());
    }
  }

  std::string authorization(const ProxySecret& secret) {
    ds::Array<char, ProxySecret::hexadecimal_bytes> hexadecimal;
    const auto user = "telar:" + std::string{*secret.formatHexadecimal(hexadecimal.viewMut())};
    ds::Array<char, 128> encoded;
    const auto count = base64::encode({reinterpret_cast<const std::uint8_t*>(user.data()), user.size()}, encoded.viewMut());

    check(count.hasValue());
    return "Proxy-Authorization: Basic " + std::string{encoded.data(), *count} + "\r\n";
  }

  void testHandshake() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    ProxyOptions options{memory};
    const auto secret = ProxySecret::generate();
    const auto credential = authorization(secret);
    ProxyCounters counters;
    auto origin = ProxyListener::bind(ds::none, {});

    for (const auto hostname : {"127.0.0.1", "fixture.invalid"}) {
      SocketPair sockets;
      ConnectHandshake<Memory, LoopbackResolver> handshake{memory, std::move(sockets.local), options, secret, counters};
      const auto request = "CONNECT " + std::string{hostname} + ":" + std::to_string(origin.port()) + " HTTP/1.1\r\n" + credential + "\r\n";

      sendBytes(sockets.remote.get(), request);
      finishHandshake(handshake);
      check(handshake.state() == decltype(handshake)::State::established);
      check(handshake.hostname() == hostname && !handshake.intercept());
      check(receiveBytes(sockets.remote.get()) == "HTTP/1.1 200 Connection Established\r\n\r\n");
      FileDescriptor accepted;
      const auto deadline = ProxyConnectionPolicy::Clock::now() + std::chrono::seconds{2};

      while (!accepted && ProxyConnectionPolicy::Clock::now() < deadline) {
        pollfd pending{.fd = origin.descriptor(), .events = POLLIN, .revents = 0};

        ::poll(&pending, 1, 10);
        accepted = origin.accept();
      }

      check(static_cast<bool>(accepted));
      int keepalive = 0;
      socklen_t length = sizeof(keepalive);

      check(::getsockopt(handshake.originDescriptor(), SOL_SOCKET, SO_KEEPALIVE, &keepalive, &length) == 0 && keepalive != 0);
    }

    {
      SocketPair sockets;
      ConnectHandshake<Memory, FailedResolver> handshake{memory, std::move(sockets.local), options, secret, counters};

      sendBytes(sockets.remote.get(), "CONNECT missing.invalid:443 HTTP/1.1\r\n" + credential + "\r\n");
      finishHandshake(handshake);
      check(receiveBytes(sockets.remote.get()) == "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
      check(counters.read(ProxyCounter::upstream_connect_failure) == 1);
    }

    {
      SocketPair sockets;
      ConnectHandshake<Memory, FailedResolver> handshake{memory, std::move(sockets.local), options, secret, counters};

      sendBytes(sockets.remote.get(), "CONNECT missing.invalid:443 HTTP/1.1\r\n\r\n");
      finishHandshake(handshake);
      check(receiveBytes(sockets.remote.get()).starts_with("HTTP/1.1 407 "));
      check(counters.read(ProxyCounter::rejected_connection) == 1 && counters.read(ProxyCounter::invalid_authorization_rejection) == 1);
    }

    {
      SocketPair sockets;
      ConnectHandshake<Memory, FailedResolver> handshake{memory, std::move(sockets.local), options, secret, counters};

      sendBytes(sockets.remote.get(), "GET / HTTP/1.1\r\n" + credential + "\r\n");
      finishHandshake(handshake);
      check(receiveBytes(sockets.remote.get()) == "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
    }

    {
      SocketPair sockets;
      ConnectHandshake<Memory, FailedResolver> handshake{memory, std::move(sockets.local), options, secret, counters};

      sendBytes(sockets.remote.get(), std::string(ConnectHead::capacity, 'a'));
      const auto started = ProxyConnectionPolicy::Clock::now();

      handshake.advance(false, started);
      check(handshake.state() == decltype(handshake)::State::draining);
      check(receiveBytes(sockets.remote.get()) == "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
      handshake.advance(false, started + std::chrono::milliseconds{200});
      check(handshake.state() == decltype(handshake)::State::closed && counters.read(ProxyCounter::connect_head_too_large) == 1);
    }
  }

  void testConnectionPolicy() {
    using Policy = ProxyConnectionPolicy;
    using Phase = Policy::Phase;
    using Closure = Policy::Closure;
    const Policy::Time start{};
    Policy policy{start};

    check(policy.expired(start + Policy::head_timeout - std::chrono::nanoseconds{1}) == Closure::none);
    check(policy.expired(start + Policy::head_timeout) == Closure::head_timeout);
    check(!policy.evictable(Closure::evict_head, start + Policy::evictable_head_age - std::chrono::nanoseconds{1}));
    check(policy.evictable(Closure::evict_head, start + Policy::evictable_head_age));
    policy.enter(Phase::establishing, start);
    check(policy.expired(start + Policy::establishment_timeout) == Closure::establishment_timeout);

    for (const auto phase : {Phase::open, Phase::idle, Phase::half_closed, Phase::closing}) {
      policy.enter(phase, start);
      policy.touch(start);
      const auto later = start + std::chrono::hours{1};

      check(policy.evictable(Closure::evict_idle, later) == (phase == Phase::idle));
      check(policy.evictable(Closure::evict_silent, later) == (phase == Phase::open));
      policy.exchanges(1);
      check(!policy.evictable(Closure::evict_idle, later) && !policy.evictable(Closure::evict_silent, later));
      policy.exchanges(0);
      check(policy.expired(later) == (phase == Phase::half_closed ? Closure::half_closed_timeout : Closure::none));
      policy.touch(later);
      check(policy.expired(later) == Closure::none);
    }
  }

  void testSocketWatch() {
    SystemAllocator memory;
    NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
    ds::Array<Event, NativeEventLoop<std::remove_reference_t<decltype(memory)>>::event_capacity> ready{};
    SocketPair sockets;
    SocketWatch watch;

    watch.update(poller, sockets.local.get(), 512, {.readable = true});
    sendBytes(sockets.remote.get(), "event");
    const auto first = poller.wait(std::chrono::seconds{1}, ready.viewMut());

    check(first.size() == 1 && watch.matches(first.front()));
    const auto stale = first.front();

    watch.update(poller, sockets.local.get(), 1024, {.readable = true});
    check(!watch.matches(stale));
    const auto second = poller.wait(std::chrono::seconds{1}, ready.viewMut());

    check(second.size() == 1 && watch.matches(second.front()) && second.front().token == 1024);

    watch.update(poller, sockets.local.get(), 1024, {.readable = true, .writable = true});
    const auto both = poller.wait(std::chrono::seconds{1}, ready.viewMut());

    check(both.size() == 2);
    check(both[0].kind != both[1].kind && watch.matches(both[0]) && watch.matches(both[1]));

    watch.update(poller, sockets.local.get(), 1024, {.readable = true});
    const auto readable = poller.wait(std::chrono::seconds{1}, ready.viewMut());

    check(readable.size() == 1 && watch.matches(readable.front()) && readable.front().kind == EventKind::readable);
    check(receiveBytes(sockets.local.get()) == "event");

    watch.update(poller, sockets.local.get(), 1024, {.writable = true});
    const auto writable = poller.wait(std::chrono::seconds{1}, ready.viewMut());

    check(writable.size() == 1 && watch.matches(writable.front()) && writable.front().kind == EventKind::writable);
    watch.remove(poller);
    check(poller.wait(std::chrono::nanoseconds{0}, ready.viewMut()).empty() && !watch.matches(stale));

    watch.update(poller, sockets.local.get(), 2048, {.readable = true});
    sendBytes(sockets.remote.get(), "retiring");
    const auto retiring = poller.wait(std::chrono::seconds{1}, ready.viewMut()).front();
    SocketPair replacement;
    const int reused_descriptor = sockets.local.get();

    watch.remove(poller);
    sockets.local.reset();
    check(!watch.matches(retiring));
    check(poller.wait(std::chrono::nanoseconds{0}, ready.viewMut()).empty());
    check(::dup2(replacement.local.get(), reused_descriptor) == reused_descriptor);
    sockets.local.reset(reused_descriptor);
    replacement.local.reset();

    watch.update(poller, reused_descriptor, 4096, {.readable = true});
    check(!watch.matches(retiring));
    sendBytes(replacement.remote.get(), "replacement");
    const auto replaced = poller.wait(std::chrono::seconds{1}, ready.viewMut());

    check(replaced.size() == 1 && watch.matches(replaced.front()) && replaced.front().token == 4096);
    check(receiveBytes(reused_descriptor) == "replacement");
    watch.remove(poller);
    sockets.local.reset();
    check(poller.wait(std::chrono::nanoseconds{0}, ready.viewMut()).empty());
    bool rejected = false;

    try {
      watch.update(poller, reused_descriptor, 8192, {.readable = true, .writable = true});
    } catch (const SystemError& error) {
      rejected = error.code() == EBADF;
    }

    check(rejected);
    watch.remove(poller);
    check(poller.wait(std::chrono::nanoseconds{0}, ready.viewMut()).empty());
  }

  void testProxyTransport() {
    testRelay<16 * 1024>();
    testRelay<32 * 1024>();
    testRelay<64 * 1024>();
    testDuplexWorkBound<16 * 1024>();
    testDuplexWorkBound<32 * 1024>();
    testDuplexWorkBound<64 * 1024>();
  }

  // A redirected TLS connection to an intercepted host is inspected before any byte reaches the
  // origin: a hello the proxy cannot act on, encrypted or malformed, closes it, and so does a hello
  // left unfinished past its 3 s window.
  void testTransparentHelloRefusals() {
    using namespace telar::runtime::tls_test;
    using Handshake = ConnectHandshake<Memory, FailedResolver>;
    using State = Handshake::State;

    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    ProxyOptions options{memory};
    const auto secret = ProxySecret::generate();
    ProxyCounters counters;

    options.transparent_tls = true;
    check(options.intercept_hosts.append("origin.test"));
    options.intercept_hosts.finish();

    struct Inspected {
      State state;
      std::string failure;
      bool intercept;
      std::string forwarded;
    };

    // Sends `bytes` from the child and advances the handshake at `start`, then at each of `later`.
    auto inspect = [&](std::span<const std::uint8_t> bytes, std::initializer_list<std::chrono::milliseconds> later = {}) {
      SocketPair child, origin;
      redirect::Connection connection{.child = std::move(child.local), .origin = std::move(origin.local)};

      connection.target.host.assign("192.0.2.1");
      Handshake handshake{memory, std::move(connection), options, secret, counters};

      sendBytes(child.remote.get(), {reinterpret_cast<const char*>(bytes.data()), bytes.size()});
      const auto start = ProxyConnectionPolicy::Clock::now();

      handshake.advance(false, start);
      for (const auto delay : later) {
        handshake.advance(false, start + delay);
      }

      return Inspected{handshake.state(), std::string{handshake.failure()}, handshake.intercept(), receiveBytes(origin.remote.get())};
    };

    const auto accepted = inspect(helloRecord(ds::Array{serverName("origin.test"), protocols()}));

    check(accepted.state == State::established && accepted.intercept);

    const auto unread = inspect(helloRecord(ds::Array{serverName("other.test"), protocols(), encryptedHello()}));

    check(unread.state == State::established && !unread.intercept);

    const auto encrypted = inspect(helloRecord(ds::Array{serverName("origin.test"), protocols(), encryptedHello()}));

    check(encrypted.state == State::closed && encrypted.failure == "tls_ech_not_supported" && encrypted.forwarded.empty());

    const auto invalid = inspect(helloRecord(ds::Array{serverName("origin.test"), protocols(), protocols()}));

    check(invalid.state == State::closed && invalid.failure == "tls_client_hello_invalid" && invalid.forwarded.empty());

    const auto hello = helloRecord(ds::Array{serverName("origin.test"), protocols()});
    const auto partial = std::span{hello}.first(10);
    const auto waiting = inspect(partial, {std::chrono::milliseconds{2900}});

    check(waiting.state == State::probing);

    const auto stalled = inspect(partial, {std::chrono::milliseconds{3000}});

    check(stalled.state == State::closed && stalled.failure == "tls_client_hello_timeout" && stalled.forwarded.empty());
  }

  // Answers only once released, as a resolver stuck on an unreachable DNS server would.
  class StalledResolver {
  public:
    static ResolutionSummary resolve(const char*, std::span<NetworkAddress>) noexcept {
      while (!released.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }

      return {.error = EAI_NONAME};
    }

    static void release() {
      released.store(true);
      const auto deadline = ProxyConnectionPolicy::Clock::now() + std::chrono::seconds{5};

      while (NameResolutions<StalledResolver>::pending() != 0) {
        check(ProxyConnectionPolicy::Clock::now() < deadline);
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }
    }

    inline static std::atomic<bool> released = false;
  };

  // A client that connects and never sends its CONNECT holds an unauthenticated slot only until the
  // head timeout closes the connection.
  void testConnectHeadTimeout() {
    using Policy = ProxyConnectionPolicy;
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ProxyOptions options{memory};
    const auto secret = ProxySecret::generate();
    ProxyCounters counters;
    SocketPair sockets;
    const auto opened = Policy::Clock::now();
    ProxyConnection<FailedResolver> connection{memory, std::move(sockets.local), options, secret, counters};

    connection.expire(opened + Policy::head_timeout - std::chrono::milliseconds{1});
    check(!connection.closed());

    connection.expire(Policy::Clock::now() + Policy::head_timeout);
    check(connection.closed() && counters.read(ProxyCounter::connect_head_timeout) == 1);
  }

  // A CONNECT whose origin never resolves is answered 504 once the establishment timeout passes,
  // instead of leaving the client waiting on a socket nobody answers.
  void testEstablishmentTimeout(TlsTestMemory& memory, const TlsLibrary& library) {
    using Policy = ProxyConnectionPolicy;
    TlsTrustStore trust{memory, library};
    TlsContexts contexts{memory, library, trust};
    const TlsInterception interception{contexts, nullptr};
    ProxyObservations observations{memory, {}};
    ProxyOptions options{memory};
    const auto secret = ProxySecret::generate();
    ProxyCounters counters;

    {
      SocketPair sockets;
      ProxyConnection<StalledResolver> connection{memory, std::move(sockets.local), options, secret, counters};

      sendBytes(sockets.remote.get(), "CONNECT stalled.test:443 HTTP/1.1\r\n" + authorization(secret) + "\r\n");
      connection.advance(interception, observations, TunnelReadiness::available(), Policy::Clock::now());
      check(!connection.closed() && receiveBytes(sockets.remote.get()).empty());

      connection.expire(Policy::Clock::now() + Policy::establishment_timeout);
      std::string response;
      const auto deadline = Policy::Clock::now() + std::chrono::seconds{5};

      while (!connection.closed()) {
        check(Policy::Clock::now() < deadline);
        connection.advance(interception, observations, TunnelReadiness::available(), Policy::Clock::now());
        response += receiveBytes(sockets.remote.get());
      }

      response += receiveBytes(sockets.remote.get());
      check(response == "HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n");
      check(counters.read(ProxyCounter::establish_timeout) == 1);
    }

    StalledResolver::release();
  }

  // With every name resolution slot taken, a CONNECT to a hostname is answered 503 at once, instead
  // of waiting on a resolution that was never started.
  void testResolutionRefused() {
    using Resolutions = NameResolutions<StalledResolver>;
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    ProxyOptions options{memory};
    const auto secret = ProxySecret::generate();
    ProxyCounters counters;
    ds::Array<ds::Option<Resolutions::Ticket>, Resolutions::capacity> tickets;

    for (std::size_t index = 0; index < tickets.size(); ++index) {
      tickets.atMut(index) = Resolutions::request("host" + std::to_string(index) + ".test");
      check(tickets[index].hasValue());
    }

    {
      SocketPair sockets;
      ConnectHandshake<Memory, StalledResolver> handshake{memory, std::move(sockets.local), options, secret, counters};

      sendBytes(sockets.remote.get(), "CONNECT refused.test:443 HTTP/1.1\r\n" + authorization(secret) + "\r\n");
      finishHandshake(handshake);
      check(receiveBytes(sockets.remote.get()) == "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
      check(counters.read(ProxyCounter::resolution_refusal) == 1);
    }

    for (auto& ticket : tickets.viewMut()) {
      ticket.reset();
    }

    StalledResolver::release();
  }

  const telar::testing::Case case_proxy_transport{"proxy_transport.proxy_transport", testProxyTransport};
  const telar::testing::Case case_connect_head{"proxy_transport.connect_head", testConnectHead};
  const telar::testing::Case case_handshake{"proxy_transport.handshake", testHandshake};
  const telar::testing::Case case_connection_policy{"proxy_transport.connection_policy", testConnectionPolicy};
  const telar::testing::Case case_socket_watch{"proxy_transport.socket_watch", testSocketWatch};
  const telar::testing::Case case_transparent_hello_refusals{"proxy_transport.transparent_hello_refusals", testTransparentHelloRefusals};
  const telar::testing::Case case_connect_head_timeout{"proxy_transport.connect_head_timeout", testConnectHeadTimeout};
  const telar::testing::Case case_establishment_timeout{"proxy_transport.establishment_timeout", withTlsLibrary<testEstablishmentTimeout>};
  const telar::testing::Case case_resolution_refused{"proxy_transport.resolution_refused", testResolutionRefused};

}
