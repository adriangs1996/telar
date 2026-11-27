module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.traffic.proxy.runtime;

import telar.platform.sha256;
import telar.sys.socket;
import telar.tls;
import telar.base.ds;

namespace telar::runtime {

  void reportProxy(std::string_view subject, std::string_view detail, std::string_view more) noexcept {
    try {
      std::println(stderr, "telar proxy {}: {}{}", subject, detail, more);
    } catch (...) {
      // A stderr that cannot be written leaves the failure unreported, as it would any line.
      return;
    }
  }

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

  tbc::val_static<std::string_view> FlowGate::failureReason() const noexcept {
    return failure_;
  }

  FlowState::~FlowState() {
    if (control_ == nullptr) {
      return;
    }

    auto closed = event(traffic::Direction::outbound);

    closed.reason = reason_;
    if (outbound_.rejected_) {
      closed.reason = outbound_.failure_;
    } else if (inbound_.rejected_) {
      closed.reason = inbound_.failure_;
    }

    control_->observeFlow(traffic::Kind::flow_close, closed);
    for (const auto* gate : {&outbound_, &inbound_}) {
      if (gate->ticket_ != 0U) {
        control_->cancel(gate->ticket_);
      }
    }
  }

  void FlowState::open(tbc::val_a<traffic::FlowControl*> control, std::uint64_t id, TunnelSockets sockets, std::string_view host) noexcept {
    control_ = control;
    identity_.id = id;
    endpoint(sockets.child, identity_.client);
    endpoint(sockets.origin, identity_.server);
    // The host is cut to its capacity first, so the assignment never throws.
    try {
      identity_.host.assign(substring(host, 0, ProxyHostname::maximum_bytes));
    } catch (...) {
      std::abort();
    }

    if (control_ != nullptr) {
      control_->observeFlow(traffic::Kind::flow_open, event(traffic::Direction::outbound));
    }
  }

  void FlowState::visibility(traffic::Visibility value) noexcept {
    identity_.visibility = value;
  }

  void FlowState::reason(tbc::val_static<std::string_view> value) noexcept {
    reason_ = value;
  }

  traffic::FlowEvent FlowState::context() const noexcept {
    return event(traffic::Direction::outbound);
  }

  void FlowState::error(tbc::val_static<std::string_view> value) noexcept {
    reason_ = value;
    if (control_ != nullptr) {
      auto failed = event(traffic::Direction::outbound);

      failed.reason = value;
      control_->observeFlow(traffic::Kind::flow_error, failed);
    }
  }

  bool FlowState::rejected() const noexcept {
    return outbound_.rejected() || inbound_.rejected();
  }

  ds::Option<traffic::FlowControl::Time> FlowState::deadline() const noexcept {
    if (control_ == nullptr) {
      return ds::none;
    }

    ds::Option<traffic::FlowControl::Time> soonest;

    if (const auto due = (outbound_.ticket_ != 0U) ? control_->deadline(outbound_.ticket_) : ds::none) {
      soonest = earliest(soonest, due);
    }

    if (const auto due = (inbound_.ticket_ != 0U) ? control_->deadline(inbound_.ticket_) : ds::none) {
      soonest = earliest(soonest, due);
    }

    return soonest;
  }

  void FlowState::fail(traffic::Direction direction, tbc::val_static<std::string_view> reason, bool reading) noexcept {
    auto& gate = this->gate(direction);
    if (gate.rejected_) {
      return;
    }

    gate.rejected_ = true;
    gate.failure_ = reason;
    if (control_ != nullptr) {
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
    return {.state = StreamResult::State::data, .bytes = count};
  }

  void FlowState::endpoint(int socket, FixedText<traffic::FlowIdentity::endpoint_bytes>& result) noexcept {
    sockaddr_storage address{};
    socklen_t size = sizeof(address);
    auto* const generic = reinterpret_cast<sockaddr*>(&address); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
    ds::Array<char, NI_MAXHOST> host{};
    ds::Array<char, NI_MAXSERV> port{};
    if (::getpeername(socket, generic, &size) != 0 || ::getnameinfo(generic, size, host.dataMut(), host.size(), port.dataMut(), port.size(), combineFlags(NI_NUMERICHOST, NI_NUMERICSERV)) != 0) {
      return;
    }

    // The endpoint is cut to one byte less than its capacity, as it always was, so neither the
    // formatting nor the assignment throws.
    ds::Array<char, traffic::FlowIdentity::endpoint_bytes> text{};
    const std::string_view name{host.data()};
    const std::string_view service{port.data()};
    const auto limit = static_cast<std::ptrdiff_t>(text.size() - 1);

    try {
      const auto written = address.ss_family == AF_INET6 ? std::format_to_n(text.dataMut(), limit, "[{}]:{}", name, service) : std::format_to_n(text.dataMut(), limit, "{}:{}", name, service);

      result.assign({text.data(), static_cast<std::size_t>(std::min(written.size, limit))});
    } catch (...) {
      std::abort();
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

  ApplicationRelay::ApplicationRelay(tbc::mut_a<ConcurrentMemory> memory, tbc::val_a<ConnectionObservation> observation, std::string_view hostname)
      : relays_{.memory_ = memory, .observation_ = observation, .http1_ = {}, .http2_ = {}, .http2_endpoint_ = {}} {
    relays_.hostname_.assign(hostname.substr(0, ProxyHostname::maximum_bytes));
  }

  bool ApplicationRelay::Relays::startHttp1(FlowState* flow) noexcept {
    try {
      Http1Capture<> capture{memory_, observation_.captures, captureStart(CaptureProtocol::http1)};
      const auto event = flow != nullptr ? flow->context() : traffic::FlowEvent{.id = observation_.identity, .host = hostname_.view()};
      const HttpRelayContext context{.control = observation_.flows != nullptr ? observation_.flows->http() : nullptr, .identity = traffic::FlowIdentity::of(event)};

      http1_ = ds::makeBox<Http1>(memory_, memory_, observation_.counters, std::move(capture), context);
      return true;
    } catch (...) {
      failed_ = true;
      return false;
    }
  }

  void ApplicationRelay::select(HttpProtocol protocol, bool unnegotiated) noexcept {
    if (!selected_) {
      if (!unnegotiated) {
        protocol_ = protocol;
      }

      selected_ = true;
    }
  }

  [[nodiscard]] auto ApplicationRelay::finished() const noexcept -> bool {
    return relays_.failed_ || (relays_.http1_ && relays_.http1_->finished()) || (relays_.http2_ && relays_.http2_->finished()) || (relays_.http2_endpoint_ && relays_.http2_endpoint_->finished()) || relays_.duplex_.finished();
  }

  [[nodiscard]] auto ApplicationRelay::halfClosed() const noexcept -> bool {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->halfClosed();
    }

    return relays_.http2_ ? relays_.http2_->halfClosed() : relays_.duplex_.halfClosed();
  }

  [[nodiscard]] auto ApplicationRelay::idle() const noexcept -> bool {
    return relays_.http1_ && relays_.http1_->idle();
  }

  [[nodiscard]] auto ApplicationRelay::inflight() const noexcept -> std::uint32_t {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->inflight();
    }

    if (relays_.http2_) {
      return relays_.http2_->inflight();
    }

    return relays_.http1_ ? relays_.http1_->inflight() : 0;
  }

  [[nodiscard]] auto ApplicationRelay::buffered() const noexcept -> bool {
    return protocol_ && !prefix_.empty() && readsChild();
  }

  [[nodiscard]] auto ApplicationRelay::readsChild() const noexcept -> bool {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->readsChild();
    }

    if (relays_.http2_) {
      return relays_.http2_->readsChild();
    }

    return relays_.http1_ && !relays_.http1_->upgraded() ? relays_.http1_->readsChild() : relays_.duplex_.readsChild();
  }

  [[nodiscard]] auto ApplicationRelay::readsOrigin() const noexcept -> bool {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->readsOrigin();
    }

    if (relays_.http2_) {
      return relays_.http2_->readsOrigin();
    }

    return relays_.http1_ && !relays_.http1_->upgraded() ? relays_.http1_->readsOrigin() : relays_.duplex_.readsOrigin();
  }

  [[nodiscard]] auto ApplicationRelay::deadline() const noexcept -> ds::Option<traffic::FlowControl::Time> {
    if (relays_.http2_endpoint_) {
      return relays_.http2_endpoint_->deadline();
    }

    if (relays_.http1_) {
      return relays_.http1_->deadline();
    }

    return !protocol_ && sniff_until_ != traffic::FlowControl::Time{} ? ds::Option{sniff_until_} : ds::none;
  }

  [[nodiscard]] auto ApplicationRelay::interest(TlsSide side) const noexcept -> SocketInterest {
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

  void ApplicationRelay::identify() noexcept {
    const auto bytes = prefix_.bytes();
    const auto head = textView(bytes);

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

    if (!http2.starts_with(head)) {
      if (const auto protocol = http1Request(head)) {
        protocol_ = *protocol;
        return;
      }
    }

    if (bytes.size() == StreamPrefix::capacity || std::chrono::steady_clock::now() >= sniff_until_) {
      protocol_ = HttpProtocol::other;
    }
  }

  ds::Option<HttpProtocol> ApplicationRelay::http1Request(std::string_view head) noexcept {
    // A request line holds no control character but tab, and no byte from DEL on.
    constexpr Byte first_printable = 0x20;
    constexpr Byte delete_character = 0x7F;
    constexpr ds::Array methods{"GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE "};

    const bool possible = std::ranges::any_of(methods, [&](std::string_view method) {
      return method.starts_with(head) || head.starts_with(method);
    });

    if (!possible) {
      return HttpProtocol::other;
    }

    const auto end = head.find("\r\n");
    if (end != std::string_view::npos) {
      const auto line = substring(head, 0, end);

      return line.ends_with(" HTTP/1.1") || line.ends_with(" HTTP/1.0") ? HttpProtocol::http11 : HttpProtocol::other;
    }

    if (std::ranges::any_of(byteView(head), [](Byte byte) {
          return byte == 0 || byte >= delete_character || (byte < first_printable && byte != '\r' && byte != '\n' && byte != '\t');
        })) {
      return HttpProtocol::other;
    }

    return ds::none;
  }

  void ApplicationRelay::identifyOrigin(std::span<const Byte> banner) noexcept {
    ds::Option<Http2Frame> initial;
    Http2FrameReader reader;

    reader.feed(banner, [&](const Http2FrameEvent& event) noexcept -> auto {
      if (event.kind == Http2FrameEvent::Kind::begin) {
        initial = event.frame;
      }
    });

    const bool h2_settings = initial && initial->kind == Http2FrameKind::settings && initial->stream == 0 && initial->flags == 0 && initial->length % Http2Frame::settings_entry_bytes == 0;

    protocol_ = h2_settings ? HttpProtocol::http2 : HttpProtocol::other;
  }

  [[nodiscard]] auto ApplicationRelay::Relays::captureStart(CaptureProtocol protocol) const noexcept -> CaptureStart {
    return {
        .key = {
            .connection = observation_.identity,
            .stream = 0,
        },
        .protocol = protocol,
        .host = hostname_.view(),
    };
  }

  PlainTunnel::PlainTunnel(tbc::mut_a<ConcurrentMemory> memory, TunnelSockets sockets, std::string_view hostname, tbc::val_a<ConnectionObservation> observation)
      : sockets_(sockets),
        application_(memory, observation, hostname) {}

  bool PlainTunnel::advance(TunnelReadiness readiness, FlowState* flow) noexcept {
    SocketStream child{sockets_.child};
    SocketStream origin{sockets_.origin};

    return application_.advance(child, origin, readiness, flow);
  }

  bool PlainTunnel::finished() const noexcept {
    return application_.finished();
  }

  bool PlainTunnel::halfClosed() const noexcept {
    return application_.halfClosed();
  }

  bool PlainTunnel::idle() const noexcept {
    return application_.idle();
  }

  std::uint32_t PlainTunnel::inflight() const noexcept {
    return application_.inflight();
  }

  bool PlainTunnel::buffered() const noexcept {
    return application_.buffered();
  }

  auto PlainTunnel::deadline() const noexcept {
    return application_.deadline();
  }

  SocketInterest PlainTunnel::interest(TlsSide side) const noexcept {
    return application_.interest(side);
  }

  TlsTunnel::TlsTunnel(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<TlsInterception> interception, TunnelRoute route, tbc::val_a<ds::Box<AlpnOffer, ConcurrentMemory>> offer, tbc::val_a<ConnectionObservation> observation)
      : observation_(observation),
        session_(interception.open(memory, route.sockets, route.hostname, std::move(offer))),
        application_(memory, observation, route.hostname) {}

  auto TlsTunnel::advance(TunnelReadiness readiness, FlowState* flow) noexcept -> bool {
    if (failed_) {
      return false;
    }

    if (!established()) {
      if (session_.getMut().advance() == TlsSession::State::failed) {
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

    // The two halves of one TLS session, each reading and writing its own side of it, as a split
    // duplex is: the session is reached by address from both, as Rust's split does with raw parts.
    auto* const session = tbc::raw(&session_.getMut());
    TlsStream child{*session, TlsSide::child};
    TlsStream origin{*session, TlsSide::origin};

    readiness.child.readable = readiness.child.readable || session_->buffered(TlsSide::child);
    readiness.origin.readable = readiness.origin.readable || session_->buffered(TlsSide::origin);
    application_.select(session_->protocol(), session_->unnegotiated());

    return application_.advance(child, origin, readiness, flow);
  }

  auto TlsTunnel::deadline() const noexcept {
    const auto session = session_->deadline();
    const auto application = application_.deadline();

    return earliest(session, application);
  }

  [[nodiscard]] auto TlsTunnel::established() const noexcept -> bool {
    return session_->state() == TlsSession::State::established;
  }

  [[nodiscard]] auto TlsTunnel::finished() const noexcept -> bool {
    return failed_ || application_.finished();
  }

  [[nodiscard]] auto TlsTunnel::halfClosed() const noexcept -> bool {
    return application_.halfClosed();
  }

  [[nodiscard]] auto TlsTunnel::idle() const noexcept -> bool {
    return application_.idle();
  }

  [[nodiscard]] auto TlsTunnel::inflight() const noexcept -> std::uint32_t {
    return application_.inflight();
  }

  [[nodiscard]] auto TlsTunnel::buffered() const noexcept -> bool {
    return application_.buffered() || (application_.readsChild() && session_->buffered(TlsSide::child)) || (application_.readsOrigin() && session_->buffered(TlsSide::origin));
  }

  [[nodiscard]] auto TlsTunnel::interest(TlsSide side) const noexcept -> SocketInterest {
    if (established()) {
      return application_.interest(side);
    }

    SocketInterest interest;

    interest.include(session_->waiting(side));
    return interest;
  }

  tbc::val_static<std::string_view> TlsTunnel::recordFailure() noexcept {
    using Failure = TlsSession::Failure;

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

  ConnectionTransport::ConnectionTransport(tbc::mut_a<ConcurrentMemory> memory) noexcept
      : memory_(memory) {}

  bool ConnectionTransport::opened() const noexcept {
    return plain_ || tls_;
  }

  bool ConnectionTransport::advance(TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.relayTunnel");
    auto* flow = flow_ ? &flow_.getMut() : nullptr;

    return plain_ ? plain_.getMut().advance(readiness, flow) : tls_.getMut().advance(readiness, flow);
  }

  bool ConnectionTransport::established() const noexcept {
    return plain_ || tls_->established();
  }

  bool ConnectionTransport::finished() const noexcept {
    return (flow_ && flow_->rejected()) || (plain_ ? plain_->finished() : tls_->finished());
  }

  bool ConnectionTransport::halfClosed() const noexcept {
    return plain_ ? plain_->halfClosed() : tls_->halfClosed();
  }

  bool ConnectionTransport::idle() const noexcept {
    return plain_ ? plain_->idle() : tls_ && tls_->idle();
  }

  std::uint32_t ConnectionTransport::inflight() const noexcept {
    if (plain_) {
      return plain_->inflight();
    }

    return tls_ ? tls_->inflight() : 0;
  }

  bool ConnectionTransport::buffered() const noexcept {
    return plain_ ? plain_->buffered() : tls_ && tls_->buffered();
  }

  SocketInterest ConnectionTransport::interest(TlsSide side) const noexcept {
    if (plain_) {
      return plain_->interest(side);
    }

    return tls_->interest(side);
  }

  ds::Option<traffic::FlowControl::Time> ConnectionTransport::deadline() const noexcept {
    const auto flow = flow_ ? flow_->deadline() : ds::none;

    if (plain_) {
      return earliest(flow, plain_->deadline());
    }

    return earliest(flow, tls_ ? tls_->deadline() : ds::none);
  }

  void ConnectionTransport::reason(tbc::val_static<std::string_view> value) noexcept {
    if (flow_) {
      flow_.getMut().reason(value);
    }
  }

  void ConnectionTransport::error(tbc::val_static<std::string_view> value) noexcept {
    if (flow_) {
      flow_.getMut().error(value);
    }
  }

  ProxyObservations::ProxyObservations(ConcurrentMemory& memory, ProxyCaptureLimits limits, traffic::FlowControl* flows)
      : captures_(memory, limits),
        capture_enabled_(limits.enabled),
        flows_(flows) {}

  ConnectionObservation ProxyObservations::connection() noexcept {
    return {.counters = counters_, .captures = capture_enabled_ ? &captures_ : nullptr, .identity = next_connection_++, .flows = flows_};
  }

  const ProxyCounters& ProxyObservations::counters() const noexcept {
    return counters_;
  }

  ProxyCounters& ProxyObservations::countersMut() noexcept {
    return counters_;
  }

  const CaptureProducer& ProxyObservations::captures() const noexcept {
    return captures_;
  }

  CaptureProducer& ProxyObservations::capturesMut() noexcept {
    return captures_;
  }

  ProxyListener ProxyListener::bind(ds::Option<std::uint16_t> preferred, const ProxyPortRange::Set& reserved) {
    if (preferred) {
      if (auto listener = tryPort(*preferred, true)) {
        return std::move(listener.getMut());
      }
    }

    for (const bool use_reserved : {false, true}) {
      for (std::uint16_t offset = 0; offset < ProxyPortRange::count; ++offset) {
        if (reserved.test(offset) != use_reserved) {
          continue;
        }

        if (auto listener = tryPort(ProxyPortRange::first + offset, false)) {
          return std::move(listener.getMut());
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

  ds::Option<ProxyListener> ProxyListener::tryPort(std::uint16_t port, bool reclaim) {
    auto socket = listen(port, false);
    if (!socket && reclaim && !answers(port)) {
      // BSD reuse can shadow a wildcard listener; reclaim only a refused port.
      socket = listen(port, true);
    }

    if (!socket) {
      return ds::none;
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
        socket.reset();
        return socket;
      }

      throw SystemError{"Bind proxy listener"};
    }

    return socket;
  }

  bool ProxyListener::answers(std::uint16_t port) noexcept {
    try {
      const auto socket = openSocket();
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
        endpoint_(memory, endpoint) {
    if (endpoint.size() > PATH_MAX || endpoint.contains('\0')) {
      throw SystemError{"Invalid proxy endpoint path", EINVAL};
    }

    identify(endpoint);
    ds::Vec<unsigned char, Memory> bytes{memory_};
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
  ds::Option<std::uint16_t> ProxyPortMemory<Memory>::preferred() const noexcept {
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

    // The port's decimal digits, then the endpoint, each ending its line.
    constexpr std::size_t port_digits = 5;

    ds::Array<char, port_digits> digits{};
    const auto digits_view = digits.viewMut();
    const auto* const digits_end = std::to_chars(digits_view.data(), std::to_address(digits_view.end()), port).ptr;
    const auto number = digits_view.first(static_cast<std::size_t>(digits_end - digits_view.data()));
    ds::Array<std::uint8_t, maximum_record_bytes> line{};
    const auto output = line.viewMut();
    std::size_t length = 0;

    std::ranges::copy(number, output.begin());
    length += number.size();
    output[length++] = '\n';
    std::ranges::copy(endpoint_.view(), output.subspan(length).begin());
    length += endpoint_.view().size();
    output[length++] = '\n';
    if (writePrivateFile(directory_, filename(), output.first(length), PrivateFileMode::replace) != 0) {
      return false;
    }

    if (!own_ && legacy_ == port) {
      ::unlinkat(directory_, legacy_name.data(), 0);
    }

    // The port is in the range, checked above, so its bit is in the set.
    if (reserved_[port - ProxyPortRange::first]) {
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

    // The bits of a byte's low hexadecimal digit.
    constexpr unsigned low_nibble_mask = 0x0FU;

    hash.update(endpoint);
    const auto digest = hash.finish();
    auto position = file_prefix.size();

    std::ranges::copy(file_prefix, name_.viewMut().begin());
    for (std::size_t index = 0; index < digest_bytes; ++index) {
      name_.atMut(position++) = hexadecimal[digest[index] >> 4U];
      name_.atMut(position++) = hexadecimal[digest[index] & low_nibble_mask];
    }

    name_.atMut(position) = '\0';
  }

  template <Allocator Memory>
  auto ProxyPortMemory<Memory>::recall(std::string_view name, tbc::mut_a<ds::Vec<unsigned char, Memory>> bytes) const noexcept -> tbc::val_a<ds::Option<Record>> {
    try {
      if (!readPrivateFile(directory_, name, bytes, maximum_record_bytes)) {
        return ds::none;
      }
    } catch (...) {
      return ds::none;
    }

    const auto text = textView(bytes.view());
    const auto newline = text.find('\n');
    auto number = trimCarriageReturns(substring(text, 0, newline));
    if (number.starts_with('+')) {
      number.remove_prefix(1);
    }

    const auto port = unsignedDecimal<std::uint16_t>(number);
    if (!port || !ProxyPortRange::contains(*port)) {
      return ds::none;
    }

    const auto tail = newline == std::string_view::npos ? std::string_view{} : substring(text, newline + 1);

    return Record{*port, trimCarriageReturns(substring(tail, 0, tail.find('\n')))};
  }

  template <Allocator Memory>
  bool ProxyPortMemory<Memory>::isPortFile(std::string_view name) noexcept {
    return name.size() == filename_bytes && name.starts_with(file_prefix) && std::ranges::all_of(substring(name, file_prefix.size()), [](char byte) {
      return hexadecimal.contains(byte);
    });
  }

  template <Allocator Memory>
  bool ProxyPortMemory<Memory>::vanished(std::string_view endpoint) noexcept {
    if (!endpoint.starts_with('/') || endpoint.contains('\0')) {
      return false;
    }

    const auto separator = endpoint.rfind('/');
    ds::Array<char, PATH_MAX + 1> parent{};
    const auto length = std::max<std::size_t>(separator, 1);
    if (length >= parent.size()) {
      return false;
    }

    std::copy_n(endpoint.data(), length, parent.dataMut());
    parent.atMut(length) = '\0';
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

  template class ProxyPortMemory<Memory>;
  template class ProxyPortMemory<ConcurrentMemory>;

}
