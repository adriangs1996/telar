module;
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <errno.h>
#include <new>
#include <unistd.h>

#include <cstdint>

#include <cassert>
#include <cstddef>
#include <cstring>

#if (defined(__linux__))
#include <cerrno>

#include <climits>
#endif
#include <fcntl.h>

#include <netinet/in.h>
#include <sys/socket.h>

#include <cstdio>
#include <netdb.h>

#include <nghttp2/nghttp2.h>

#include <arpa/inet.h>

#include <stdlib.h>

#include <ctime>
#include <limits.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <sys/stat.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif

#include <sys/types.h>

#include <poll.h>

#include <dirent.h>
#include <openssl/sha.h>

#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#include <sys/resource.h>

module telar.runtime.proxy.runtime;

namespace telar::runtime {

  void SocketInterest::include(StreamReadiness readiness) noexcept {
    readable = readable || readiness == StreamReadiness::readable;
    writable = writable || readiness == StreamReadiness::writable;
    completion = completion || readiness == StreamReadiness::completion;
  }

  [[nodiscard]] auto SocketInterest::satisfies(StreamReadiness readiness) const noexcept -> bool {
    return (readiness == StreamReadiness::readable && readable) || (readiness == StreamReadiness::writable && writable) || (readiness == StreamReadiness::completion && completion);
  }

  bool SocketWatch::matches(const Event& event) const noexcept {
    return descriptor_ >= 0 && event.descriptor == descriptor_ && event.token == token_;
  }

  bool FlowGate::rejected() const noexcept {
    return rejected_;
  }

  tbc::view<std::string_view, tbc::lt::static_storage> FlowGate::failureReason() const noexcept {
    return failure_;
  }

  FlowState::~FlowState() {
    if (!control_) {
      return;
    }

    auto closed = event(traffic::Direction::outbound);

    closed.reason = outbound_.rejected_ ? outbound_.failure_ : inbound_.rejected_ ? inbound_.failure_
                                                                                  : reason_;
    control_->observeFlow(traffic::Kind::flow_close, closed);
    for (const auto* gate : {&outbound_, &inbound_}) {
      if (gate->ticket_) {
        control_->cancel(gate->ticket_);
      }
    }
  }

  void FlowState::open(tbc::view<traffic::FlowControl*, tbc::lt::a> control, std::uint64_t id, int child, int origin, std::string_view host) noexcept {
    control_ = control;
    identity_.id = id;
    endpoint(child, identity_.client);
    endpoint(origin, identity_.server);
    identity_.host.assign(host.substr(0, ProxyHostname::maximum_bytes));
    if (control_) {
      control_->observeFlow(traffic::Kind::flow_open, event(traffic::Direction::outbound));
    }
  }

  void FlowState::visibility(traffic::Visibility value) noexcept {
    identity_.visibility = value;
  }

  void FlowState::reason(tbc::view<std::string_view, tbc::lt::static_storage> value) noexcept {
    reason_ = value;
  }

  traffic::FlowEvent FlowState::context() const noexcept {
    return event(traffic::Direction::outbound);
  }

  void FlowState::error(tbc::view<std::string_view, tbc::lt::static_storage> value) noexcept {
    reason_ = value;
    if (control_) {
      auto failed = event(traffic::Direction::outbound);

      failed.reason = value;
      control_->observeFlow(traffic::Kind::flow_error, failed);
    }
  }

  bool FlowState::rejected() const noexcept {
    return outbound_.rejected() || inbound_.rejected();
  }

  std::optional<traffic::FlowControl::Time> FlowState::deadline() const noexcept {
    std::optional<traffic::FlowControl::Time> soonest;

    for (const auto* gate : {&outbound_, &inbound_}) {
      if (const auto due = gate->ticket_ ? control_->deadline(gate->ticket_) : std::nullopt) {
        soonest = earliest(soonest, due);
      }
    }

    return soonest;
  }

  void FlowState::fail(traffic::Direction direction, tbc::view<std::string_view, tbc::lt::static_storage> reason, bool reading) noexcept {
    auto& gate = this->gate(direction);
    if (gate.rejected_) {
      return;
    }

    gate.rejected_ = true;
    gate.failure_ = reason;
    if (control_) {
      auto failed = event(reading ? opposite(direction) : direction);

      failed.offset = gate.offset_;
      failed.reason = reason;
      control_->observeFlow(traffic::Kind::flow_error, failed);
    }
  }

  traffic::Direction FlowState::opposite(traffic::Direction direction) noexcept {
    return direction == traffic::Direction::outbound ? traffic::Direction::inbound : traffic::Direction::outbound;
  }

  FlowGate& FlowState::gate(traffic::Direction direction) noexcept {
    return direction == traffic::Direction::outbound ? outbound_ : inbound_;
  }

  traffic::FlowEvent FlowState::event(traffic::Direction direction) const noexcept {
    return identity_.event(direction);
  }

  StreamResult FlowState::complete(FlowGate& gate) noexcept {
    const auto count = gate.original_size_;

    eraseSensitive(gate.replacement_.bytes().data(), gate.replacement_size_);
    gate.offered_ = gate.replacing_ = false;
    gate.sent_ = gate.replacement_size_ = 0;
    return {StreamResult::State::data, count};
  }

  void FlowState::endpoint(int socket, FixedText<traffic::FlowIdentity::endpoint_bytes>& result) noexcept {
    sockaddr_storage address{};
    socklen_t size = sizeof(address);
    std::array<char, NI_MAXHOST> host{};
    std::array<char, NI_MAXSERV> port{};
    if (::getpeername(socket, reinterpret_cast<sockaddr*>(&address), &size) == 0 && ::getnameinfo(reinterpret_cast<sockaddr*>(&address), size, host.data(), host.size(), port.data(), port.size(), NI_NUMERICHOST | NI_NUMERICSERV) == 0) {
      std::array<char, 128> text{};

      std::snprintf(text.data(), text.size(), address.ss_family == AF_INET6 ? "[%s]:%s" : "%s:%s", host.data(), port.data());
      result.assign(text.data());
    }
  }

  std::span<const std::uint8_t> StreamPrefix::bytes() noexcept {
    return storage_.bytes().subspan(offset_, length_ - offset_);
  }

  bool StreamPrefix::empty() const noexcept {
    return offset_ == length_;
  }

  void StreamPrefix::consume(std::size_t count) noexcept {
    offset_ += count;
  }

  template <ConcurrentAllocator Memory>
  ApplicationRelay<Memory>::ApplicationRelay(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<ConnectionObservation<Memory>, tbc::lt::a> observation, std::string_view hostname)
      : relays_{.memory_ = memory, .observation_ = observation, .http1_ = {nullptr, AllocationDeleter<Http1, Memory>{memory}}, .http2_ = {nullptr, AllocationDeleter<Http2, Memory>{memory}}, .http2_endpoint_ = {nullptr, AllocationDeleter<Http2Endpoint, Memory>{memory}}} {
    relays_.hostname_.assign(hostname.substr(0, ProxyHostname::maximum_bytes));
  }

  template <ConcurrentAllocator Memory>
  void ApplicationRelay<Memory>::select(HttpProtocol protocol, bool unnegotiated) noexcept {
    if (!selected_) {
      if (!unnegotiated) {
        protocol_ = protocol;
      }

      selected_ = true;
    }
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::finished() const noexcept -> bool {
    return relays_.failed_ || (relays_.http1_ && relays_.http1_->finished()) || (relays_.http2_ && relays_.http2_->finished()) || (relays_.http2_endpoint_ && relays_.http2_endpoint_->finished()) || relays_.duplex_.finished();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::halfClosed() const noexcept -> bool {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->halfClosed();
    }

    return relays_.http2_ ? relays_.http2_->halfClosed() : relays_.duplex_.halfClosed();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::idle() const noexcept -> bool {
    return relays_.http1_ && relays_.http1_->idle();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::inflight() const noexcept -> std::uint32_t {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->inflight();
    }

    return relays_.http2_ ? relays_.http2_->inflight() : relays_.http1_ ? relays_.http1_->inflight()
                                                                        : 0;
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::buffered() const noexcept -> bool {
    return protocol_ && !prefix_.empty() && readsChild();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::readsChild() const noexcept -> bool {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->readsChild();
    }

    return relays_.http2_ ? relays_.http2_->readsChild() : relays_.http1_ && !relays_.http1_->upgraded() ? relays_.http1_->readsChild()
                                                                                                         : relays_.duplex_.readsChild();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::readsOrigin() const noexcept -> bool {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->readsOrigin();
    }

    return relays_.http2_ ? relays_.http2_->readsOrigin() : relays_.http1_ && !relays_.http1_->upgraded() ? relays_.http1_->readsOrigin()
                                                                                                          : relays_.duplex_.readsOrigin();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::deadline() const noexcept -> std::optional<traffic::FlowControl::Time> {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->deadline();
    }

    if (relays_.http1_) {
      return relays_.http1_->deadline();
    }

    return !protocol_ && sniff_until_ != traffic::FlowControl::Time{} ? std::optional{sniff_until_} : std::nullopt;
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::interest(TlsSide side) const noexcept -> SocketInterest {
    if (!protocol_ && !prefix_.empty()) {
      return {.readable = side == TlsSide::child};
    }

    if (relays_.http2_endpoint_) {
      return side == TlsSide::child ? relays_.http2_endpoint_->childInterest() : relays_.http2_endpoint_->originInterest();
    }

    if (relays_.http1_ && !relays_.http1_->upgraded()) {
      return side == TlsSide::child ? relays_.http1_->childInterest() : relays_.http1_->originInterest();
    }

    if (relays_.http2_) {
      return side == TlsSide::child ? relays_.http2_->childInterest() : relays_.http2_->originInterest();
    }

    return side == TlsSide::child ? relays_.duplex_.childInterest() : relays_.duplex_.originInterest();
  }

  template <ConcurrentAllocator Memory>
  void ApplicationRelay<Memory>::identify() noexcept {
    const auto bytes = prefix_.bytes();
    const std::string_view head{reinterpret_cast<const char*>(bytes.data()), bytes.size()};

    if (head.empty()) {
      return;
    }

    if (sniff_until_ == traffic::FlowControl::Time{}) {
      sniff_until_ = std::chrono::steady_clock::now() + std::chrono::seconds{3};
    }

    constexpr std::string_view http2 = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    if (head.starts_with(http2)) {
      protocol_ = HttpProtocol::http2;
      return;
    }

    const bool h2_prefix = http2.starts_with(head);
    if (!h2_prefix) {
      constexpr std::array methods{"GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE "};
      const bool possible = std::ranges::any_of(methods, [&](std::string_view method) {
        return method.starts_with(head) || head.starts_with(method);
      });

      if (!possible) {
        protocol_ = HttpProtocol::other;
        return;
      }

      const auto end = head.find("\r\n");
      if (end != std::string_view::npos) {
        const auto line = head.substr(0, end);

        protocol_ = line.ends_with(" HTTP/1.1") || line.ends_with(" HTTP/1.0") ? HttpProtocol::http11 : HttpProtocol::other;
        return;
      }

      if (std::ranges::any_of(bytes, [](Byte byte) {
            return byte == 0 || byte >= 127 || (byte < 32 && byte != '\r' && byte != '\n' && byte != '\t');
          })) {
        protocol_ = HttpProtocol::other;
        return;
      }
    }

    if (bytes.size() == StreamPrefix::capacity || std::chrono::steady_clock::now() >= sniff_until_) {
      protocol_ = HttpProtocol::other;
    }
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto ApplicationRelay<Memory>::Relays::captureStart(CaptureProtocol protocol) const noexcept -> CaptureStart {
    return {
        .key = {
            observation_.identity,
            0,
        },
        .protocol = protocol,
        .host = hostname_.view(),
    };
  }

  template <ConcurrentAllocator Memory>
  PlainTunnel<Memory>::PlainTunnel(tbc::view<Memory&, tbc::lt::a> memory, TunnelSockets sockets, std::string_view hostname, tbc::view<ConnectionObservation<Memory>, tbc::lt::a> observation)
      : sockets_(sockets),
        application_(memory, observation, hostname) {}

  template <ConcurrentAllocator Memory>
  bool PlainTunnel<Memory>::advance(TunnelReadiness readiness, FlowState* flow) noexcept {
    SocketStream child{sockets_.child}, origin{sockets_.origin};

    return application_.advance(child, origin, readiness, flow);
  }

  template <ConcurrentAllocator Memory>
  bool PlainTunnel<Memory>::finished() const noexcept {
    return application_.finished();
  }

  template <ConcurrentAllocator Memory>
  bool PlainTunnel<Memory>::halfClosed() const noexcept {
    return application_.halfClosed();
  }

  template <ConcurrentAllocator Memory>
  bool PlainTunnel<Memory>::idle() const noexcept {
    return application_.idle();
  }

  template <ConcurrentAllocator Memory>
  std::uint32_t PlainTunnel<Memory>::inflight() const noexcept {
    return application_.inflight();
  }

  template <ConcurrentAllocator Memory>
  bool PlainTunnel<Memory>::buffered() const noexcept {
    return application_.buffered();
  }

  template <ConcurrentAllocator Memory>
  auto PlainTunnel<Memory>::deadline() const noexcept {
    return application_.deadline();
  }

  template <ConcurrentAllocator Memory>
  SocketInterest PlainTunnel<Memory>::interest(TlsSide side) const noexcept {
    return application_.interest(side);
  }

  template <ConcurrentAllocator Memory>
  TlsTunnel<Memory>::TlsTunnel(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<const TlsInterception<Memory>&, tbc::lt::a> interception, TunnelSockets sockets, std::string_view hostname, tbc::view<Owned<AlpnOffer, Memory>, tbc::lt::a> offer, tbc::view<ConnectionObservation<Memory>, tbc::lt::a> observation)
      : observation_(observation),
        session_(interception.open(memory, sockets, hostname, std::move(offer))),
        application_(memory, observation, hostname) {}

  template <ConcurrentAllocator Memory>
  auto TlsTunnel<Memory>::advance(TunnelReadiness readiness, FlowState* flow) noexcept -> bool {
    if (failed_) {
      return false;
    }

    if (!established()) {
      if (session_->advance() == TlsSession<Memory>::State::failed) {
        const auto reason = recordFailure();

        if (flow != nullptr) {
          flow->error(reason);
        }

        failed_ = true;
        return false;
      }

      if (!established()) {
        return false;
      }

      if (flow != nullptr) {
        flow->visibility(traffic::Visibility::plaintext);
      }

      readiness = TunnelReadiness::available();
    }

    TlsStream child{*session_, TlsSide::child};
    TlsStream origin{*session_, TlsSide::origin};

    readiness.child.readable = readiness.child.readable || session_->buffered(TlsSide::child);
    readiness.origin.readable = readiness.origin.readable || session_->buffered(TlsSide::origin);
    application_.select(session_->protocol(), session_->unnegotiated());

    return application_.advance(child, origin, readiness, flow);
  }

  template <ConcurrentAllocator Memory>
  auto TlsTunnel<Memory>::deadline() const noexcept {
    const auto session = session_->deadline();
    const auto application = application_.deadline();

    return earliest(session, application);
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::established() const noexcept -> bool {
    return session_->state() == TlsSession<Memory>::State::established;
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::finished() const noexcept -> bool {
    return failed_ || application_.finished();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::halfClosed() const noexcept -> bool {
    return application_.halfClosed();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::idle() const noexcept -> bool {
    return application_.idle();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::inflight() const noexcept -> std::uint32_t {
    return application_.inflight();
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::buffered() const noexcept -> bool {
    return application_.buffered() || (application_.readsChild() && session_->buffered(TlsSide::child)) || (application_.readsOrigin() && session_->buffered(TlsSide::origin));
  }

  template <ConcurrentAllocator Memory>
  [[nodiscard]] auto TlsTunnel<Memory>::interest(TlsSide side) const noexcept -> SocketInterest {
    if (established()) {
      return application_.interest(side);
    }

    SocketInterest interest;

    interest.include(session_->waiting(side));
    return interest;
  }

  template <ConcurrentAllocator Memory>
  tbc::view<std::string_view, tbc::lt::static_storage> TlsTunnel<Memory>::recordFailure() noexcept {
    using Failure = typename TlsSession<Memory>::Failure;

    switch (session_->failure()) {
    case Failure::context:
      observation_.counters.record(ProxyCounter::tls_context_failure);
      return "tls_context_failed";
    case Failure::client_hello:
      observation_.counters.record(ProxyCounter::tls_downstream_handshake_failure);
      return "tls_client_hello_failed";
    case Failure::origin_handshake:
      observation_.counters.record(ProxyCounter::tls_upstream_handshake_failure);
      return "tls_origin_handshake_failed";
    case Failure::child_handshake:
      observation_.counters.record(ProxyCounter::tls_downstream_handshake_failure);
      return "tls_client_handshake_failed";
    case Failure::mint:
      observation_.counters.record(ProxyCounter::tls_mint_failure);
      return "tls_certificate_mint_failed";
    case Failure::none:
      break;
    }

    return "tls_handshake_failed";
  }

  template <ConcurrentAllocator Memory>
  ConnectionTransport<Memory>::ConnectionTransport(tbc::view<Memory&, tbc::lt::a> memory) noexcept
      : memory_(memory),
        flow_(nullptr, AllocationDeleter<FlowState, Memory>{memory}),
        plain_(nullptr, AllocationDeleter<PlainTunnel<Memory>, Memory>{memory}),
        tls_(nullptr, AllocationDeleter<TlsTunnel<Memory>, Memory>{memory}) {}

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::opened() const noexcept {
    return plain_ || tls_;
  }

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::advance(TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.relayTunnel");
    return plain_ ? plain_->advance(readiness, flow_.get()) : tls_->advance(readiness, flow_.get());
  }

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::established() const noexcept {
    return plain_ || tls_->established();
  }

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::finished() const noexcept {
    return (flow_ && flow_->rejected()) || (plain_ ? plain_->finished() : tls_->finished());
  }

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::halfClosed() const noexcept {
    return plain_ ? plain_->halfClosed() : tls_->halfClosed();
  }

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::idle() const noexcept {
    return plain_ ? plain_->idle() : tls_ && tls_->idle();
  }

  template <ConcurrentAllocator Memory>
  std::uint32_t ConnectionTransport<Memory>::inflight() const noexcept {
    return plain_ ? plain_->inflight() : tls_ ? tls_->inflight()
                                              : 0;
  }

  template <ConcurrentAllocator Memory>
  bool ConnectionTransport<Memory>::buffered() const noexcept {
    return plain_ ? plain_->buffered() : tls_ && tls_->buffered();
  }

  template <ConcurrentAllocator Memory>
  SocketInterest ConnectionTransport<Memory>::interest(TlsSide side) const noexcept {
    if (plain_) {
      return plain_->interest(side);
    }

    return tls_->interest(side);
  }

  template <ConcurrentAllocator Memory>
  std::optional<traffic::FlowControl::Time> ConnectionTransport<Memory>::deadline() const noexcept {
    const auto flow = flow_ ? flow_->deadline() : std::nullopt;
    const auto tls = plain_ ? plain_->deadline() : tls_ ? tls_->deadline()
                                                        : std::nullopt;

    return earliest(flow, tls);
  }

  template <ConcurrentAllocator Memory>
  void ConnectionTransport<Memory>::reason(tbc::view<std::string_view, tbc::lt::static_storage> value) noexcept {
    if (flow_) {
      flow_->reason(value);
    }
  }

  template <ConcurrentAllocator Memory>
  void ConnectionTransport<Memory>::error(tbc::view<std::string_view, tbc::lt::static_storage> value) noexcept {
    if (flow_) {
      flow_->error(value);
    }
  }

  template <ConcurrentAllocator Memory>
  ProxyObservations<Memory>::ProxyObservations(Memory& memory, ProxyCaptureLimits limits, traffic::FlowControl* flows)
      : captures(memory, limits),
        capture_enabled_(limits.enabled),
        flows_(flows) {}

  template <ConcurrentAllocator Memory>
  ConnectionObservation<Memory> ProxyObservations<Memory>::connection() noexcept {
    return {counters, capture_enabled_ ? &captures : nullptr, next_connection_++, flows_};
  }

  ProxyClientConfiguration::ProxyClientConfiguration(std::shared_ptr<const Identity> identity) noexcept
      : identity_(std::move(identity)) {}

  const ProxyStatus& ProxyClientConfiguration::status() const noexcept {
    return identity_ ? identity_->status : inactive;
  }

  void ProxyClientConfiguration::environment(void* target, void (*set)(void* target, std::string_view name, std::string_view value)) const {
    if (!identity_ || !identity_->status.active) {
      return;
    }

    if (identity_->https_proxy) {
      SensitiveBuffer<256> storage;
      const auto bytes = storage.bytes();
      const auto url = identity_->secret.formatUrl({reinterpret_cast<char*>(bytes.data()), bytes.size()}, *identity_->status.port);
      if (!url) {
        throw SystemError{"Format child proxy URL", EOVERFLOW};
      }

      set(target, "HTTPS_PROXY", *url);
      set(target, "https_proxy", *url);
      set(target, "NODE_USE_ENV_PROXY", "1");
    }

    set(target, "NODE_EXTRA_CA_CERTS", identity_->certificate.view());
    for (const auto name : {"SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "AWS_CA_BUNDLE", "GIT_SSL_CAINFO", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"}) {
      set(target, name, identity_->bundle.view());
    }

    set(target, "TELAR_PROXY_TLS", "1");
  }

  ProxyListener ProxyListener::bind(std::optional<std::uint16_t> preferred, const ProxyPortRange::Set& reserved) {
    if (preferred) {
      if (auto listener = tryPort(*preferred, true)) {
        return std::move(*listener);
      }
    }

    for (const bool use_reserved : {false, true}) {
      for (std::uint16_t offset = 0; offset < ProxyPortRange::count; ++offset) {
        if (reserved.test(offset) != use_reserved) {
          continue;
        }

        if (auto listener = tryPort(ProxyPortRange::first + offset, false)) {
          return std::move(*listener);
        }
      }
    }

    throw SystemError{"No proxy port available", EADDRINUSE};
  }

  FileDescriptor ProxyListener::accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (!child) {
      if (socketWouldBlock(sys::lastError())) {
        return child;
      }

      throw SystemError{"Accept proxy connection"};
    }

    configureProxySocket(child.get());
    return child;
  }

  int ProxyListener::descriptor() const noexcept {
    return socket_.get();
  }

  std::uint16_t ProxyListener::port() const noexcept {
    return port_;
  }

  void ProxyListener::close() noexcept {
    socket_.reset();
  }

  ProxyListener::ProxyListener(FileDescriptor socket, std::uint16_t port) noexcept
      : socket_(std::move(socket)),
        port_(port) {}

  FileDescriptor ProxyListener::openSocket() {
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};
    if (!socket) {
      throw SystemError{"Create proxy socket"};
    }

    configureProxySocket(socket.get());
    return socket;
  }

  NetworkAddress ProxyListener::address(std::uint16_t port) noexcept {
    return NetworkAddress::ipv4(in_addr{.s_addr = htonl(INADDR_LOOPBACK)}, port);
  }

  std::optional<ProxyListener> ProxyListener::tryPort(std::uint16_t port, bool reclaim) {
    auto socket = listen(port, false);
    if (!socket && reclaim && !answers(port)) {
      // BSD reuse can shadow a wildcard listener; reclaim only a refused port.
      socket = listen(port, true);
    }

    if (!socket) {
      return std::nullopt;
    }

    return ProxyListener{std::move(socket), port};
  }

  FileDescriptor ProxyListener::listen(std::uint16_t port, bool reuse_closed) {
    auto socket = openSocket();

    if (reuse_closed) {
      const int enabled = 1;
      if (::setsockopt(socket.get(), SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Reclaim proxy port"};
      }
    }

    const auto loopback = address(port);
    if (::bind(socket.get(), loopback.address(), loopback.length) != 0 || ::listen(socket.get(), backlog) != 0) {
      if (sys::lastError() == EADDRINUSE) {
        return FileDescriptor{};
      }

      throw SystemError{"Bind proxy listener"};
    }

    return socket;
  }

  bool ProxyListener::answers(std::uint16_t port) noexcept {
    try {
      auto socket = openSocket();
      const auto loopback = address(port);
      if (::connect(socket.get(), loopback.address(), loopback.length) == 0) {
        return true;
      }

      if (sys::lastError() == ECONNREFUSED) {
        return false;
      }

      if (sys::lastError() != EINPROGRESS) {
        return true;
      }

      pollfd pending{.fd = socket.get(), .events = POLLOUT, .revents = 0};
      if (::poll(&pending, 1, probe_timeout_ms) != 1) {
        return true;
      }

      int failure = 0;
      socklen_t length = sizeof(failure);

      return ::getsockopt(socket.get(), SOL_SOCKET, SO_ERROR, &failure, &length) != 0 || failure != ECONNREFUSED;
    } catch (...) {
      return true;
    }
  }

  template <Allocator Memory>
  ProxyPortMemory<Memory>::ProxyPortMemory(Memory& memory, int directory, std::string_view endpoint, bool inherit_legacy)
      : memory_(memory),
        directory_(directory),
        endpoint_(endpoint, AllocatorRef<char, Memory>{memory}) {
    if (endpoint.size() > PATH_MAX || endpoint.contains('\0')) {
      throw SystemError{"Invalid proxy endpoint path", EINVAL};
    }

    identify(endpoint);
    Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
    if (const auto record = recall(name_.data(), bytes)) {
      own_ = record->port;
    }

    if (inherit_legacy) {
      if (const auto record = recall(legacy_name, bytes)) {
        legacy_ = record->port;
      }
    }

    scan([&](const char* name, const Record& record) {
      if (vanished(record.endpoint)) {
        ::unlinkat(directory_, name, 0);
      } else {
        reserved_.set(record.port - ProxyPortRange::first);
      }
    });

    if (own_ && legacy_) {
      reserved_.set(*legacy_ - ProxyPortRange::first);
    }
  }

  template <Allocator Memory>
  std::optional<std::uint16_t> ProxyPortMemory<Memory>::preferred() const noexcept {
    return own_ ? own_ : legacy_;
  }

  template <Allocator Memory>
  const ProxyPortRange::Set& ProxyPortMemory<Memory>::reserved() const noexcept {
    return reserved_;
  }

  template <Allocator Memory>
  std::string_view ProxyPortMemory<Memory>::filename() const noexcept {
    return {name_.data(), filename_bytes};
  }

  template <Allocator Memory>
  bool ProxyPortMemory<Memory>::remember(std::uint16_t port) noexcept {
    if (!ProxyPortRange::contains(port)) {
      return false;
    }

    std::array<char, maximum_record_bytes> record;
    auto* end = std::to_chars(record.data(), record.data() + record.size(), port).ptr;

    *end++ = '\n';
    end = std::copy(endpoint_.begin(), endpoint_.end(), end);
    *end++ = '\n';
    const auto bytes = std::span{reinterpret_cast<const std::uint8_t*>(record.data()), static_cast<std::size_t>(end - record.data())};
    if (writePrivateFile(directory_, filename(), bytes, PrivateFileMode::replace) != 0) {
      return false;
    }

    if (!own_ && legacy_ == port) {
      ::unlinkat(directory_, legacy_name, 0);
    }

    if (reserved_.test(port - ProxyPortRange::first)) {
      scan([&](const char* name, const Record& record) {
        if (record.port == port) {
          ::unlinkat(directory_, name, 0);
        }
      });
    }

    return true;
  }

  template <Allocator Memory>
  void ProxyPortMemory<Memory>::DirectoryCloser::operator()(DIR* directory) const noexcept {
    ::closedir(directory);
  }

  template <Allocator Memory>
  void ProxyPortMemory<Memory>::identify(std::string_view endpoint) noexcept {
    Sha256 hash;

    hash.update(endpoint);
    const auto digest = hash.finish();
    auto* end = std::copy(file_prefix.begin(), file_prefix.end(), name_.begin());

    for (std::size_t index = 0; index < digest_bytes; ++index) {
      *end++ = hexadecimal[digest[index] >> 4];
      *end++ = hexadecimal[digest[index] & 15];
    }

    *end = '\0';
  }

  template <Allocator Memory>
  auto ProxyPortMemory<Memory>::recall(std::string_view name, tbc::view<Vector<unsigned char, Memory>&, tbc::lt::a> bytes) const noexcept -> tbc::view<std::optional<Record>, tbc::lt::a> {
    try {
      if (!readPrivateFile(directory_, name, bytes, maximum_record_bytes)) {
        return std::nullopt;
      }
    } catch (...) {
      return std::nullopt;
    }

    const std::string_view text{reinterpret_cast<const char*>(bytes.data()), bytes.size()};
    const auto newline = text.find('\n');
    auto number = trimCarriageReturns(text.substr(0, newline));
    if (number.starts_with('+')) {
      number.remove_prefix(1);
    }

    const auto port = unsignedDecimal<std::uint16_t>(number);
    if (!port || !ProxyPortRange::contains(*port)) {
      return std::nullopt;
    }

    const auto tail = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);

    return Record{*port, trimCarriageReturns(tail.substr(0, tail.find('\n')))};
  }

  template <Allocator Memory>
  bool ProxyPortMemory<Memory>::isPortFile(std::string_view name) noexcept {
    return name.size() == filename_bytes && name.starts_with(file_prefix) && std::ranges::all_of(name.substr(file_prefix.size()), [](char byte) {
      return hexadecimal.contains(byte);
    });
  }

  template <Allocator Memory>
  bool ProxyPortMemory<Memory>::vanished(std::string_view endpoint) noexcept {
    if (!endpoint.starts_with('/') || endpoint.contains('\0')) {
      return false;
    }

    const auto separator = endpoint.rfind('/');
    std::array<char, PATH_MAX + 1> parent;
    const auto length = std::max<std::size_t>(separator, 1);
    if (length >= parent.size()) {
      return false;
    }

    std::copy_n(endpoint.data(), length, parent.data());
    parent[length] = '\0';
    struct stat metadata{};

    return ::stat(parent.data(), &metadata) != 0 && sys::lastError() == ENOENT;
  }

  template <Allocator Memory>
  std::string_view ProxyPortMemory<Memory>::trimCarriageReturns(std::string_view text) noexcept {
    while (text.ends_with('\r')) {
      text.remove_suffix(1);
    }

    return text;
  }

  ProxyRefusal::ProxyRefusal(FileDescriptor socket, ProxyConnectionPolicy::Time now) noexcept
      : socket_(std::move(socket)),
        deadline_(now + drain_duration) {}

  bool ProxyRefusal::advance(ProxyConnectionPolicy::Time now) noexcept {
    if (now >= deadline_) {
      return true;
    }

    SocketStream stream{socket_.get()};

    if (!response_.sent()) {
      const auto sent = response_.write(stream);
      if (sent.state != StreamResult::State::data) {
        return sent.state != StreamResult::State::blocked;
      }

      if (!response_.sent()) {
        return false;
      }

      stream.halfClose();
    }

    return drainEnded(stream);
  }

  int ProxyRefusal::descriptor() const noexcept {
    return socket_.get();
  }

  SocketInterest ProxyRefusal::interest() const noexcept {
    return {.readable = response_.sent(), .writable = !response_.sent()};
  }

  ProxyConnectionPolicy::Time ProxyRefusal::deadline() const noexcept {
    return deadline_;
  }

  template struct ConnectionObservation<ConcurrentMemory>;
  template class ApplicationRelay<ConcurrentMemory>;
  template class PlainTunnel<ConcurrentMemory>;
  template class TlsTunnel<ConcurrentMemory>;
  template class ConnectionTransport<ConcurrentMemory>;
  template class ProxyObservations<ConcurrentMemory>;
  template class ProxyPortMemory<Memory>;
  template class ProxyPortMemory<ConcurrentMemory>;

}
