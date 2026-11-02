#pragma once

#include "../memory/fixed_text.hpp"
#include "../platform/byte_stream.hpp"
#include "../platform/stream_read_buffer.hpp"
#include "../platform/tunnel_sockets.hpp"
#include "alpn_offer.hpp"
#include "authority.hpp"
#include "contexts.hpp"
#include "side.hpp"
#include <arpa/inet.h>
#include <chrono>
#include <optional>
#include <memory>

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsSession {
public:
  enum class State {
    initialize,
    offer,
    origin,
    child,
    established,
    failed
  };

  enum class Failure {
    none,
    context,
    client_hello,
    origin_handshake,
    child_handshake,
    mint
  };

  explicit TlsSession(const TlsContexts<Memory> &contexts, const CertificateAuthority<Memory> &authority, TunnelSockets sockets, std::string_view hostname, std::shared_ptr<const CertificateAuthority<Memory>> owner = {})
      : contexts_(contexts),
        authority_owner_(std::move(owner)),
        authority_(authority),
        sockets_(sockets) {
    requireTls(TlsHostname::valid(hostname), "Invalid TLS session hostname");
    hostname_.assign(hostname);
  }

  ~TlsSession() {
    if (child_) {
      SSL_shutdown(child_.get());
    }
    if (origin_) {
      SSL_shutdown(origin_.get());
    }
  }

  TlsSession(const TlsSession &) = delete;
  TlsSession &operator=(const TlsSession &) = delete;

  State advance() noexcept {
    TELAR_TRACE("tls.advanceHandshake");
    try {
      if (state_ == State::initialize) {
        initialize();
      }
      if (state_ == State::offer) {
        const auto now = std::chrono::steady_clock::now();
        if (now < offer_after_) { return state_; }
        const auto read = offer_.peek(sockets_.child);
        if (read == AlpnOffer::Read::pending) {
          offer_after_ = now + std::chrono::milliseconds{2};
          return state_;
        }
        failure_ = Failure::client_hello;
        requireTls(read == AlpnOffer::Read::complete, "Read TLS ClientHello");
        const auto names = offer_.encoded();
        failure_ = Failure::origin_handshake;
        requireTls(SSL_set_alpn_protos(origin_.get(), names.data(), static_cast<unsigned>(names.size())) == 0, "Set TLS origin ALPN offer");
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

  State state() const noexcept {
    return state_;
  }

  Failure failure() const noexcept {
    return state_ == State::failed ? failure_ : Failure::none;
  }

  StreamReadiness waiting(TlsSide side) const noexcept {
    if (side == TlsSide::child) {
      return state_ == State::offer ? (offer_after_ == std::chrono::steady_clock::time_point{} ? StreamReadiness::readable : StreamReadiness::none) : state_ == State::child ? child_waiting_
                                                                                         : StreamReadiness::none;
    }
    return state_ == State::origin ? origin_waiting_ : StreamReadiness::none;
  }

  std::optional<std::chrono::steady_clock::time_point> deadline() const noexcept {
    return state_ == State::offer && offer_after_ != std::chrono::steady_clock::time_point{} ? std::optional{offer_after_} : std::nullopt;
  }

  HttpProtocol protocol() const noexcept {
    const auto selected = selection_.protocol();
    if (selected.size() == 2 && selected[0] == 'h' && selected[1] == '2') { return HttpProtocol::http2; }
    constexpr std::string_view http11 = "http/1.1";
    return std::ranges::equal(selected, http11) ? HttpProtocol::http11 : HttpProtocol::other;
  }

  bool unnegotiated() const noexcept { return selection_.protocol().empty(); }

  StreamResult read(TlsSide side, std::span<std::uint8_t> destination) noexcept {
    auto &buffer = input(side);
    if (!buffer.empty()) {
      return {StreamResult::State::data, buffer.copyTo(destination)};
    }
    return readNative(side, destination);
  }

  StreamResult write(TlsSide side, std::span<const std::uint8_t> bytes) noexcept {
    if (state_ != State::established) {
      return {StreamResult::State::failed};
    }
    ERR_clear_error();
    std::size_t sent = 0;
    auto *connection = endpoint(side);
    const int result = SSL_write_ex(connection, bytes.data(), bytes.size(), &sent);
    return result == 1 ? StreamResult{StreamResult::State::data, sent} : ioFailure(connection, result);
  }

  StreamResult peek(TlsSide side, std::span<std::uint8_t> destination) noexcept {
    const auto visible = peekView(side, destination.size());
    if (!visible.bytes.empty()) {
      std::memcpy(destination.data(), visible.bytes.data(), visible.bytes.size());
    }
    return {visible.state, visible.bytes.size(), visible.waiting};
  }

  StreamView peekView(TlsSide side, std::size_t maximum) noexcept {
    return input(side).peek([&](std::span<std::uint8_t> destination) noexcept { return readNative(side, destination); }, maximum);
  }

  void consume(TlsSide side, std::size_t count) noexcept {
    input(side).consume(count);
  }

  bool buffered(TlsSide side) const noexcept {
    const auto &buffer = side == TlsSide::child ? child_input_ : origin_input_;
    return state_ == State::established && (!buffer.empty() || SSL_pending(endpoint(side)) > 0);
  }

  void halfClose(TlsSide side) noexcept {
    ::shutdown(side == TlsSide::child ? sockets_.child : sockets_.origin, SHUT_WR);
  }

private:
  StreamResult readNative(TlsSide side, std::span<std::uint8_t> destination) noexcept {
    if (state_ != State::established) {
      return {StreamResult::State::failed};
    }
    ERR_clear_error();
    std::size_t received = 0;
    auto *connection = endpoint(side);
    const int result = SSL_read_ex(connection, destination.data(), destination.size(), &received);
    return result == 1 ? StreamResult{StreamResult::State::data, received} : ioFailure(connection, result);
  }

  auto &input(TlsSide side) noexcept {
    return side == TlsSide::child ? child_input_ : origin_input_;
  }

  void initialize() {
    failure_ = Failure::context;
    origin_.reset(SSL_new(contexts_.origin()));
    child_.reset(SSL_new(contexts_.child()));
    requireTls(origin_ != nullptr && child_ != nullptr, "Allocate TLS connections");
    requireTls(SSL_set_fd(origin_.get(), sockets_.origin) == 1 && SSL_set_fd(child_.get(), sockets_.child) == 1, "Attach TLS sockets");
    SSL_set_connect_state(origin_.get());
    SSL_set_accept_state(child_.get());
    SSL_set_app_data(child_.get(), &selection_);

    std::array<char, ProxyHostname::maximum_bytes + 1> terminated{};
    std::copy(hostname_.view().begin(), hostname_.view().end(), terminated.begin());
    in6_addr numeric;
    if (::inet_pton(AF_INET, terminated.data(), &numeric) == 1 || ::inet_pton(AF_INET6, terminated.data(), &numeric) == 1) {
      requireTls(X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(origin_.get()), terminated.data()) == 1, "Set TLS origin IP verification");
    } else {
      requireTls(SSL_set1_host(origin_.get(), terminated.data()) == 1, "Set TLS origin hostname verification");
      requireTls(SSL_set_tlsext_host_name(origin_.get(), terminated.data()) == 1, "Set TLS origin server name");
    }

    failure_ = Failure::mint;
    const auto leaf = authority_.mint(hostname_.view());
    requireTls(SSL_use_certificate(child_.get(), leaf.certificate.get()) == 1 && SSL_use_PrivateKey(child_.get(), leaf.key.get()) == 1 && SSL_add1_chain_cert(child_.get(), authority_.certificate()) == 1, "Configure TLS child certificate");
    state_ = State::offer;
  }

  static bool handshake(SSL *connection, StreamReadiness &waiting) {
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

  void mirrorProtocol() {
    const unsigned char *selected = nullptr;
    unsigned length = 0;
    SSL_get0_alpn_selected(origin_.get(), &selected, &length);
    requireTls(selection_.assign({selected, length}), "Invalid TLS origin ALPN selection");
  }

  static StreamResult ioFailure(SSL *connection, int result) noexcept {
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

  SSL *endpoint(TlsSide side) const noexcept {
    return side == TlsSide::child ? child_.get() : origin_.get();
  }

  std::chrono::steady_clock::time_point offer_after_{};
  static constexpr std::size_t read_capacity = 16 * 1024;
  StreamReadBuffer<read_capacity> child_input_;
  StreamReadBuffer<read_capacity> origin_input_;

  const TlsContexts<Memory> &contexts_;
  std::shared_ptr<const CertificateAuthority<Memory>> authority_owner_;
  const CertificateAuthority<Memory> &authority_;
  TunnelSockets sockets_;
  FixedText<ProxyHostname::maximum_bytes> hostname_;
  AlpnOffer offer_;
  AlpnSelection selection_;
  TlsConnection origin_;
  TlsConnection child_;
  State state_ = State::initialize;
  Failure failure_ = Failure::none;
  StreamReadiness origin_waiting_ = StreamReadiness::writable;
  StreamReadiness child_waiting_ = StreamReadiness::readable;
};

}
