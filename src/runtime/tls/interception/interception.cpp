module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.tls.interception;

import telar.sys.socket;
import telar.tls;
import telar.base.ds;

namespace telar::runtime {

  AlpnOffer::AlpnOffer() noexcept {}

  auto AlpnOffer::peek(int socket) noexcept -> Read {
    const auto count = ::recv(socket, bytes_.dataMut(), bytes_.size(), MSG_PEEK);
    if (count <= 0) {
      return count < 0 && socketWouldBlock(sys::lastError()) ? Read::pending : Read::ended;
    }

    tls_ = bytes_[0] == handshake_record;
    if (!tls_) {
      return Read::complete;
    }

    const auto available = static_cast<std::size_t>(count);
    std::size_t cursor = 0, collected = 0;

    while (cursor < available) {
      if (available - cursor < record_header_bytes) {
        return incomplete(available);
      }

      const auto* header = bytes_.data() + cursor;
      const std::size_t length = (std::size_t{header[3]} << 8) | header[4];
      if (header[0] != handshake_record || header[1] != 3 || length == 0 || length > maximum_record_bytes) {
        return Read::complete;
      }

      if (available - cursor - record_header_bytes < length) {
        return incomplete(available);
      }

      std::memmove(bytes_.dataMut() + collected, header + record_header_bytes, length);
      collected += length;
      cursor += record_header_bytes + length;
      if (collected >= 4) {
        const auto expected = (std::size_t{bytes_[1]} << 16) | (std::size_t{bytes_[2]} << 8) | bytes_[3];
        if (expected > maximum_hello_bytes - 4 || bytes_[0] != client_hello) {
          return Read::complete;
        }

        if (collected >= expected + 4) {
          parseStored(expected + 4);
          return Read::complete;
        }
      }
    }

    return incomplete(available);
  }

  void AlpnOffer::parse(std::span<const std::uint8_t> handshake) noexcept {
    if (handshake.size() > bytes_.size()) {
      parseStored(0);
      return;
    }

    std::ranges::copy(handshake, bytes_.viewMut().begin());
    parseStored(handshake.size());
  }

  bool AlpnOffer::tls() const noexcept {
    return tls_;
  }

  bool AlpnOffer::valid() const noexcept {
    return valid_;
  }

  bool AlpnOffer::encrypted() const noexcept {
    return encrypted_;
  }

  std::string_view AlpnOffer::serverName() const noexcept {
    return server_name_.view();
  }

  std::span<const std::uint8_t> AlpnOffer::encoded() const noexcept {
    return std::span{bytes_}.subspan(protocols_offset_, protocols_size_);
  }

  void AlpnOffer::parseStored(std::size_t size) noexcept {
    const auto handshake = std::span<const std::uint8_t>{bytes_}.first(size);

    protocols_offset_ = protocols_size_ = 0;
    valid_ = false;
    encrypted_ = false;
    server_name_.assign({});
    Cursor record{handshake};
    if (record.byte() != client_hello) {
      return;
    }

    const auto declared = record.take(handshake_length_bytes);
    if (declared.size() != 3 || ((std::size_t{declared[0]} << 16) | (std::size_t{declared[1]} << 8) | declared[2]) != record.remaining()) {
      return;
    }

    record.take(version_bytes + random_bytes);
    record.take(record.byte());
    const auto ciphers = record.word();
    if (ciphers == 0 || ciphers % 2 != 0) {
      return;
    }

    record.take(ciphers);
    record.take(record.byte());
    if (record.failed()) {
      return;
    }

    if (record.empty()) {
      valid_ = true;
      return;
    }

    const auto extension_bytes = record.take(record.word());

    if (record.failed() || !record.empty()) {
      return;
    }

    bool seen_alpn = false, seen_name = false;
    Cursor extensions{extension_bytes};

    while (!extensions.empty()) {
      const auto kind = extensions.word();
      const auto body = extensions.take(extensions.word());

      if (extensions.failed()) {
        return;
      }

      if (kind == alpn_extension) {
        if (seen_alpn) {
          return;
        }

        seen_alpn = true;
        if (!protocols(body)) {
          return;
        }
      } else if (kind == 0) {
        if (seen_name || !serverName(body)) {
          return;
        }

        seen_name = true;
      } else if (kind == 0xfe0d) {
        encrypted_ = true;
      }
    }

    valid_ = true;
  }

  AlpnOffer::Cursor::Cursor(std::span<const std::uint8_t> bytes) noexcept
      : bytes_(bytes) {}

  std::span<const std::uint8_t> AlpnOffer::Cursor::take(std::size_t count) noexcept {
    if (count > bytes_.size()) {
      failed_ = true;
      bytes_ = {};
      return {};
    }

    const auto result = bytes_.first(count);

    bytes_ = bytes_.subspan(count);
    return result;
  }

  std::uint8_t AlpnOffer::Cursor::byte() noexcept {
    const auto value = take(1);

    return value.empty() ? 0 : value.front();
  }

  std::uint16_t AlpnOffer::Cursor::word() noexcept {
    const auto value = take(2);

    return value.empty() ? 0 : static_cast<std::uint16_t>((std::uint16_t{value[0]} << 8) | value[1]);
  }

  bool AlpnOffer::Cursor::failed() const noexcept {
    return failed_;
  }

  bool AlpnOffer::Cursor::empty() const noexcept {
    return bytes_.empty();
  }

  std::size_t AlpnOffer::Cursor::remaining() const noexcept {
    return bytes_.size();
  }

  auto AlpnOffer::incomplete(std::size_t count) const noexcept -> Read {
    return count == bytes_.size() ? Read::complete : Read::pending;
  }

  bool AlpnOffer::serverName(std::span<const std::uint8_t> extension) noexcept {
    Cursor names{extension};
    const auto length = names.word();
    if (names.failed() || length != names.remaining()) {
      return false;
    }

    while (!names.empty()) {
      const auto type = names.byte();
      const auto value = names.take(names.word());

      if (names.failed()) {
        return false;
      }

      if (type == 0) {
        const std::string_view host{reinterpret_cast<const char*>(value.data()), value.size()};
        if (!server_name_.view().empty() || !ProxyHostname::validTarget(host)) {
          return false;
        }

        server_name_.assign(host);
      }
    }

    return true;
  }

  bool AlpnOffer::protocols(std::span<const std::uint8_t> extension) noexcept {
    Cursor names{extension};
    const auto declared = names.word();
    if (names.failed() || declared == 0 || declared != names.remaining()) {
      return false;
    }

    while (!names.empty()) {
      const auto length = names.byte();

      names.take(length);
      if (names.failed() || length == 0) {
        return false;
      }
    }

    protocols_offset_ = static_cast<std::size_t>(extension.data() - bytes_.data()) + 2;
    protocols_size_ = extension.size() - 2;
    return true;
  }

  bool AlpnSelection::assign(std::span<const unsigned char> protocol) noexcept {
    if (protocol.size() > name_.size()) {
      return false;
    }

    std::copy(protocol.begin(), protocol.end(), name_.dataMut());
    length_ = static_cast<unsigned char>(protocol.size());
    return true;
  }

  std::span<const unsigned char> AlpnSelection::protocol() const noexcept {
    return std::span{name_}.first(length_);
  }

  int AlpnSelection::select(SSL* connection, const unsigned char** selected, unsigned char* length, const unsigned char* offered, unsigned offered_length, void*) noexcept {
    const auto* selection = static_cast<const AlpnSelection*>(SSL_get_app_data(connection));
    if (selection == nullptr || selection->length_ == 0) {
      return SSL_TLSEXT_ERR_NOACK;
    }

    std::span<const unsigned char> names{offered, offered_length};

    while (!names.empty()) {
      const auto size = names.front();

      names = names.subspan(1);
      if (size > names.size()) {
        return SSL_TLSEXT_ERR_ALERT_FATAL;
      }

      if (std::ranges::equal(names.first(size), selection->protocol())) {
        *selected = selection->name_.data();
        *length = selection->length_;
        return SSL_TLSEXT_ERR_OK;
      }

      names = names.subspan(size);
    }

    return SSL_TLSEXT_ERR_ALERT_FATAL;
  }

  TlsTrustStore::TlsTrustStore(ConcurrentMemory& memory, const TlsLibrary& library) {
    requireTls(library.uses(memory), "TLS trust allocator does not match its library");
    store_.reset(X509_STORE_new());
    requireTls(store_ != nullptr, "Allocate TLS trust store");
  }

  void TlsTrustStore::addDer(std::span<const unsigned char> encoded) {
    requireTls(!encoded.empty() && encoded.size() <= maximum_certificate_bytes, "Invalid TLS root certificate size");
    auto* position = encoded.data();
    TlsCertificate certificate{d2i_X509(nullptr, &position, static_cast<long>(encoded.size()))};

    requireTls(certificate != nullptr && position == encoded.data() + encoded.size(), "Decode TLS root certificate");
    add(certificate.get());
  }

  void TlsTrustStore::add(X509* certificate) {
    TlsHandle<ASN1_TIME, ASN1_TIME_free> now{ASN1_TIME_set(nullptr, std::time(nullptr))};

    requireTls(now != nullptr, "Read TLS trust validation time");
    const int expiration = ASN1_TIME_compare(X509_get0_notAfter(certificate), now.get());

    requireTls(expiration != -2, "Invalid TLS root expiration");
    if (expiration < 0) {
      return;
    }

    // A copy of the store's object list, taken under its lock; get0 handed out the store's own list.
    const TlsObjects objects{X509_STORE_get1_objects(store_.get())};

    requireTls(objects != nullptr, "Read TLS trust anchors");
    for (int index = 0; index < sk_X509_OBJECT_num(objects.get()); ++index) {
      const auto* object = sk_X509_OBJECT_value(objects.get(), index);
      if (X509_OBJECT_get_type(object) != X509_LU_X509) {
        continue;
      }

      const auto* existing = X509_OBJECT_get0_X509(object);
      if (X509_cmp(existing, certificate) == 0) {
        return;
      }
    }

    requireTls(X509_STORE_add_cert(store_.get(), certificate) == 1, "Add TLS trust anchor");
    ++count_;
  }

  X509_STORE* TlsTrustStore::native() const noexcept {
    return store_.get();
  }

  std::size_t TlsTrustStore::count() const noexcept {
    return count_;
  }

  TlsContexts::TlsContexts(ConcurrentMemory& memory, const TlsLibrary& library, const TlsTrustStore& trust) {
    requireTls(library.uses(memory), "TLS contexts allocator does not match its library");
    origin_.reset(SSL_CTX_new(TLS_client_method()));
    child_.reset(SSL_CTX_new(TLS_server_method()));
    requireTls(origin_ != nullptr && child_ != nullptr, "Allocate TLS contexts");

    for (auto* context : {origin_.get(), child_.get()}) {
      requireTls(SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1, "Set TLS minimum version");
      // A TCP half-close ends only the receiving direction. HTTP framing
      // determines whether that EOF truncates an unfinished message.
      SSL_CTX_set_options(context, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION | SSL_OP_IGNORE_UNEXPECTED_EOF);
      SSL_CTX_set_mode(context, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
      SSL_CTX_set_session_cache_mode(context, SSL_SESS_CACHE_OFF);
    }

    SSL_CTX_set_verify(origin_.get(), SSL_VERIFY_PEER, nullptr);
    requireTls(SSL_CTX_set1_verify_cert_store(origin_.get(), trust.native()) == 1, "Set TLS origin trust");
    requireTls(SSL_CTX_set_num_tickets(child_.get(), 0) == 1, "Disable TLS session tickets");
    SSL_CTX_set_alpn_select_cb(child_.get(), &AlpnSelection::select, nullptr);
  }

  SSL_CTX* TlsContexts::origin() const noexcept {
    return origin_.get();
  }

  SSL_CTX* TlsContexts::child() const noexcept {
    return child_.get();
  }

  TlsSession::TlsSession(tbc::view<const TlsContexts&, tbc::lt::a> contexts, tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority, TunnelSockets sockets, std::string_view hostname, tbc::view<ConcurrentMemory&, tbc::lt::a> memory, tbc::view<ds::Box<AlpnOffer, ConcurrentMemory>, tbc::lt::a> offer)
      : contexts_(contexts),
        authority_(std::move(authority)),
        sockets_(sockets),
        offered_(offer.hasValue()),
        offer_(offer ? std::move(offer) : ds::makeBox<AlpnOffer>(memory)) {
    requireTls(authority_ != nullptr, "TLS authority is unavailable");
    requireTls(TlsHostname::valid(hostname), "Invalid TLS session hostname");
    hostname_.assign(hostname);
  }

  TlsSession::~TlsSession() {
    if (child_) {
      SSL_shutdown(child_.get());
    }

    if (origin_) {
      SSL_shutdown(origin_.get());
    }
  }

  auto TlsSession::advance() noexcept -> State {
    TELAR_TRACE("tls.advanceHandshake");
    try {
      if (state_ == State::initialize) {
        initialize();
      }

      if (state_ == State::offer) {
        if (!offered_) {
          const auto now = std::chrono::steady_clock::now();
          if (now < offer_after_) {
            return state_;
          }

          const auto read = offer_.getMut().peek(sockets_.child);
          if (read == AlpnOffer::Read::pending) {
            offer_after_ = now + std::chrono::milliseconds{2};
            return state_;
          }

          failure_ = Failure::client_hello;
          requireTls(read == AlpnOffer::Read::complete, "Read TLS ClientHello");
        }

        const auto names = offer_->encoded();

        failure_ = Failure::origin_handshake;
        // OpenSSL copies the protocols, so the offer is done with.
        requireTls(SSL_set_alpn_protos(origin_.get(), names.data(), static_cast<unsigned>(names.size())) == 0, "Set TLS origin ALPN offer");
        offer_.reset();
        state_ = State::origin;
      }

      if (state_ == State::origin && handshake(origin_.get(), origin_waiting_)) {
        mirrorProtocol();
        state_ = State::child;
        failure_ = Failure::child_handshake;
      }

      if (state_ == State::child && handshake(child_.get(), child_waiting_)) {
        state_ = State::established;
        failure_ = Failure::none;
      }
    } catch (...) {
      state_ = State::failed;
    }

    return state_;
  }

  auto TlsSession::state() const noexcept -> State {
    return state_;
  }

  auto TlsSession::failure() const noexcept -> Failure {
    return state_ == State::failed ? failure_ : Failure::none;
  }

  StreamReadiness TlsSession::waiting(TlsSide side) const noexcept {
    if (side == TlsSide::child) {
      return state_ == State::offer ? (offer_after_ == std::chrono::steady_clock::time_point{} ? StreamReadiness::readable : StreamReadiness::none) : state_ == State::child ? child_waiting_
                                                                                                                                                                             : StreamReadiness::none;
    }

    return state_ == State::origin ? origin_waiting_ : StreamReadiness::none;
  }

  ds::Option<std::chrono::steady_clock::time_point> TlsSession::deadline() const noexcept {
    return state_ == State::offer && offer_after_ != std::chrono::steady_clock::time_point{} ? ds::Option{offer_after_} : ds::none;
  }

  HttpProtocol TlsSession::protocol() const noexcept {
    const auto selected = selection_.protocol();
    if (selected.size() == 2 && selected[0] == 'h' && selected[1] == '2') {
      return HttpProtocol::http2;
    }

    constexpr std::string_view http11 = "http/1.1";

    return std::ranges::equal(selected, http11) ? HttpProtocol::http11 : HttpProtocol::other;
  }

  bool TlsSession::unnegotiated() const noexcept {
    return selection_.protocol().empty();
  }

  auto& TlsSession::input(TlsSide side) noexcept {
    return side == TlsSide::child ? child_input_ : origin_input_;
  }

  StreamResult TlsSession::read(TlsSide side, std::span<std::uint8_t> destination) noexcept {
    auto& buffer = input(side);
    if (!buffer.empty()) {
      return {StreamResult::State::data, buffer.copyTo(destination)};
    }

    return readNative(side, destination);
  }

  StreamResult TlsSession::write(TlsSide side, std::span<const std::uint8_t> bytes) noexcept {
    if (state_ != State::established) {
      return {StreamResult::State::failed};
    }

    ERR_clear_error();
    std::size_t sent = 0;
    auto* connection = endpoint(side);
    const int result = SSL_write_ex(connection, bytes.data(), bytes.size(), &sent);

    return result == 1 ? StreamResult{StreamResult::State::data, sent} : ioFailure(connection, result);
  }

  StreamResult TlsSession::peek(TlsSide side, std::span<std::uint8_t> destination) noexcept {
    const auto visible = peekView(side, destination.size());
    if (!visible.bytes.empty()) {
      std::memcpy(destination.data(), visible.bytes.data(), visible.bytes.size());
    }

    return {visible.state, visible.bytes.size(), visible.waiting};
  }

  StreamView TlsSession::peekView(TlsSide side, std::size_t maximum) noexcept {
    return input(side).peek([&](std::span<std::uint8_t> destination) noexcept {
      return readNative(side, destination);
    },
        maximum);
  }

  void TlsSession::consume(TlsSide side, std::size_t count) noexcept {
    input(side).consume(count);
  }

  bool TlsSession::buffered(TlsSide side) const noexcept {
    const auto& buffer = side == TlsSide::child ? child_input_ : origin_input_;

    return state_ == State::established && (!buffer.empty() || SSL_pending(endpoint(side)) > 0);
  }

  void TlsSession::halfClose(TlsSide side) noexcept {
    ::shutdown(side == TlsSide::child ? sockets_.child : sockets_.origin, SHUT_WR);
  }

  StreamResult TlsSession::readNative(TlsSide side, std::span<std::uint8_t> destination) noexcept {
    if (state_ != State::established) {
      return {StreamResult::State::failed};
    }

    ERR_clear_error();
    std::size_t received = 0;
    auto* connection = endpoint(side);
    const int result = SSL_read_ex(connection, destination.data(), destination.size(), &received);

    return result == 1 ? StreamResult{StreamResult::State::data, received} : ioFailure(connection, result);
  }

  void TlsSession::initialize() {
    failure_ = Failure::context;
    origin_.reset(SSL_new(contexts_.origin()));
    child_.reset(SSL_new(contexts_.child()));
    requireTls(origin_ != nullptr && child_ != nullptr, "Allocate TLS connections");
    requireTls(SSL_set_fd(origin_.get(), sockets_.origin) == 1 && SSL_set_fd(child_.get(), sockets_.child) == 1, "Attach TLS sockets");
    SSL_set_connect_state(origin_.get());
    SSL_set_accept_state(child_.get());
    SSL_set_app_data(child_.get(), &selection_);

    ds::Array<char, ProxyHostname::maximum_bytes + 1> terminated{};

    std::copy(hostname_.view().begin(), hostname_.view().end(), terminated.dataMut());
    if (TlsHostname::numeric(hostname_.view())) {
      requireTls(X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(origin_.get()), terminated.data()) == 1, "Set TLS origin IP verification");
    } else {
      requireTls(SSL_set1_dnsname(origin_.get(), terminated.data()) == 1, "Set TLS origin hostname verification");
      requireTls(SSL_set_tlsext_host_name(origin_.get(), terminated.data()) == 1, "Set TLS origin server name");
    }

    failure_ = Failure::mint;
    const auto leaf = authority_->mint(hostname_.view());

    requireTls(SSL_use_certificate(child_.get(), leaf.certificate.get()) == 1 && SSL_use_PrivateKey(child_.get(), leaf.key.get()) == 1 && SSL_add1_chain_cert(child_.get(), authority_->certificate()) == 1, "Configure TLS child certificate");
    state_ = State::offer;
  }

  bool TlsSession::handshake(SSL* connection, StreamReadiness& waiting) {
    ERR_clear_error();
    const int result = SSL_do_handshake(connection);
    if (result == 1) {
      waiting = StreamReadiness::none;
      return true;
    }

    const auto failure = ioFailure(connection, result);

    requireTls(failure.state == StreamResult::State::blocked, "TLS handshake failed");
    waiting = failure.waiting;
    return false;
  }

  void TlsSession::mirrorProtocol() {
    const unsigned char* selected = nullptr;
    unsigned length = 0;

    SSL_get0_alpn_selected(origin_.get(), &selected, &length);
    requireTls(selection_.assign({selected, length}), "Invalid TLS origin ALPN selection");
  }

  StreamResult TlsSession::ioFailure(SSL* connection, int result) noexcept {
    switch (SSL_get_error(connection, result)) {
    case SSL_ERROR_WANT_READ:
      return {StreamResult::State::blocked, 0, StreamReadiness::readable};
    case SSL_ERROR_WANT_WRITE:
      return {StreamResult::State::blocked, 0, StreamReadiness::writable};
    case SSL_ERROR_ZERO_RETURN:
      return {StreamResult::State::ended};
    default:
      return {StreamResult::State::failed};
    }
  }

  SSL* TlsSession::endpoint(TlsSide side) const noexcept {
    return side == TlsSide::child ? child_.get() : origin_.get();
  }

  TlsInterception::TlsInterception(tbc::view<const TlsContexts&, tbc::lt::a> contexts, tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority) noexcept
      : contexts_(contexts),
        replacement_(std::move(authority)) {}

  tbc::view<ds::Box<TlsSession, ConcurrentMemory>, tbc::lt::a> TlsInterception::open(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, TunnelSockets sockets, std::string_view hostname, tbc::view<ds::Box<AlpnOffer, ConcurrentMemory>, tbc::lt::a> offer) const {
    requireTls(!suspended_.load(std::memory_order_acquire), "TLS authority synchronization is in progress");
    return ds::makeBox<TlsSession>(memory, contexts_, snapshot(), sockets, hostname, memory, std::move(offer));
  }

  tbc::view<ds::Box<TlsSession, ConcurrentMemory>, tbc::lt::a> TlsInterception::open(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, TunnelSockets sockets, std::string_view hostname) const {
    return open(memory, sockets, hostname, ds::Box<AlpnOffer, ConcurrentMemory>{});
  }

  tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> TlsInterception::snapshot() const noexcept {
    std::lock_guard lock{mutex_};

    return replacement_;
  }

  void TlsInterception::replace(tbc::view<std::shared_ptr<const CertificateAuthority>, tbc::lt::a> authority) noexcept {
    std::lock_guard lock{mutex_};

    replacement_.swap(authority);
  }

  void TlsInterception::suspend(bool value) noexcept {
    suspended_.store(value, std::memory_order_release);
  }

  bool TlsInterception::suspended() const noexcept {
    return suspended_.load(std::memory_order_acquire);
  }

  TlsStream::TlsStream(TlsSession& session, TlsSide side) noexcept
      : session_(session),
        side_(side) {}

  StreamResult TlsStream::read(std::span<std::uint8_t> destination) noexcept {
    return session_.read(side_, destination);
  }

  StreamResult TlsStream::peek(std::span<std::uint8_t> destination) noexcept {
    return session_.peek(side_, destination);
  }

  StreamView TlsStream::peekView(std::size_t maximum) noexcept {
    return session_.peekView(side_, maximum);
  }

  void TlsStream::consume(std::size_t count) noexcept {
    session_.consume(side_, count);
  }

  StreamResult TlsStream::write(std::span<const std::uint8_t> bytes) noexcept {
    return session_.write(side_, bytes);
  }

  void TlsStream::halfClose() noexcept {
    session_.halfClose(side_);
  }

}
