#pragma once

#include "../memory/fixed_text.hpp"
#include "authenticate.hpp"
#include "connect_head.hpp"
#include "connection_policy.hpp"
#include "counters.hpp"
#include "options.hpp"
#include "origin_connection.hpp"
#include "../redirect/connection.hpp"
#include "../tls/alpn_offer.hpp"

namespace telar::runtime {

template <Allocator Memory, HostnameResolver Resolver>
class ConnectHandshake {
public:
  using Time = ProxyConnectionPolicy::Time;

  enum class State {
    reading,
    probing,
    establishing,
    replying,
    draining,
    established,
    closed
  };

  explicit ConnectHandshake(FileDescriptor child, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters) noexcept
      : child_(std::move(child)),
        options_(options),
        secret_(secret),
        counters_(counters) {}

  explicit ConnectHandshake(redirect::Connection connection, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters) noexcept
      : child_(std::move(connection.child)), options_(options), secret_(secret), counters_(counters), adopted_origin_(std::move(connection.origin)), state_(State::established), transparent_(true) {
    hostname_.assign(connection.target.host.view());
    if (options_.transparent_tls) { state_ = State::probing; }
  }

  void advance(bool origin_writable, Time now) noexcept {
    TELAR_TRACE("proxy.connectHandshake");
    if (state_ == State::probing) { probe(now); }
    if (state_ == State::reading) {
      readHead(now);
    }
    if (state_ == State::establishing) {
      connectOrigin(origin_writable);
    }
    if (state_ == State::replying) {
      writeResponse(now);
    }
    if (state_ == State::draining) {
      drain(now);
    }
  }

  void expire() noexcept {
    if (state_ == State::reading) {
      counters_.record(ProxyCounter::connect_head_timeout);
      state_ = State::closed;
    } else if (state_ == State::establishing) {
      counters_.record(ProxyCounter::establish_timeout);
      origin_.reset();
      respond("HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n");
    }
  }

  State state() const noexcept {
    return state_;
  }

  std::optional<Time> deadline() const noexcept {
    if (state_ == State::probing && probe_until_ != Time{}) { return std::min(probe_until_, probe_after_); }
    return state_ == State::draining ? std::optional{drain_until_} : std::nullopt;
  }

  int childDescriptor() const noexcept {
    return child_.get();
  }

  int originDescriptor() const noexcept {
    if (transparent_) {
      return adopted_origin_.get();
    }
    return origin_ ? origin_->descriptor() : -1;
  }

  std::size_t originAttempt() const noexcept {
    if (transparent_) {
      return 1;
    }
    return origin_ ? origin_->attempt() : 0;
  }

  bool wantsChildRead() const noexcept {
    return state_ == State::reading || state_ == State::draining || (state_ == State::probing && probe_after_ == Time{});
  }

  bool wantsChildWrite() const noexcept {
    return state_ == State::replying;
  }

  bool wantsOriginRead() const noexcept { return state_ == State::probing && !hello_.tls(); }

  std::string_view failure() const noexcept { return failure_; }

  bool wantsOriginWrite() const noexcept {
    return state_ == State::establishing && origin_ && origin_->state() == Origin::State::connecting;
  }

  std::string_view hostname() const noexcept {
    return hostname_.view();
  }

  bool intercept() const noexcept {
    return transparent_ ? inspected_ : options_.intercept_hosts.contains(hostname_.view());
  }

private:
  using Origin = OriginConnection<Resolver>;

  void probe(Time now) noexcept {
    if (!hello_.tls()) {
      std::uint8_t byte;
      const auto count = ::recv(adopted_origin_.get(), &byte, 1, MSG_PEEK);
      if (count > 0) { state_ = State::established; return; }
      if (count == 0 || (count < 0 && !socketWouldBlock(errno))) { state_ = State::closed; failure_ = "origin_closed_before_client_hello"; return; }
    }
    if (probe_until_ == Time{}) { probe_until_ = now + std::chrono::seconds{3}; }
    if (now < probe_after_) { return; }
    const auto read = hello_.peek(child_.get());
    if (read == AlpnOffer::Read::pending) {
      if (now >= probe_until_) {
        state_ = hello_.tls() ? State::closed : State::established;
        failure_ = "tls_client_hello_timeout";
      }
      probe_after_ = now + std::chrono::milliseconds{2};
      return;
    }
    if (read == AlpnOffer::Read::ended) { state_ = State::closed; return; }
    if (!hello_.tls()) { state_ = State::established; return; }
    const auto name = hello_.serverName();
    const auto host = name.empty() ? hostname_.view() : name;
    inspected_ = options_.intercept_hosts.contains(host);
    if (inspected_ && (!hello_.valid() || hello_.encrypted())) {
      failure_ = hello_.encrypted() ? "tls_ech_not_supported" : "tls_client_hello_invalid";
      state_ = State::closed;
      return;
    }
    if (inspected_ && !name.empty()) { hostname_.assign(name); }
    state_ = State::established;
  }

  void readHead(Time now) noexcept {
    switch (head_.receive(child_.get())) {
    case ConnectHead::Read::pending:
      return;
    case ConnectHead::Read::ended:
      state_ = State::closed;
      return;
    case ConnectHead::Read::too_large:
      counters_.record(ProxyCounter::connect_head_too_large);
      drain_until_ = now + refusal_drain;
      respond("HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
      return;
    case ConnectHead::Read::complete:
      break;
    }

    const auto decision = authenticateProxy(secret_, options_.anonymous_tunnels, options_.intercept_hosts, head_.text());
    if (const auto *rejected = std::get_if<ProxyRejection>(&decision)) {
      if (rejected->reason != ProxyRejection::Reason::invalid_target) {
        counters_.record(ProxyCounter::rejected_connection);
        counters_.record(rejected->reason == ProxyRejection::Reason::unknown_credential ? ProxyCounter::unknown_credential_rejection : ProxyCounter::invalid_authorization_rejection);
      }
      respond(rejected->response());
      head_.erase();
      return;
    }

    const auto &admission = std::get<ProxyAdmission>(decision);
    if (!admission.authenticated) {
      counters_.record(ProxyCounter::anonymous_tunnel);
    }
    hostname_.assign(admission.target.hostname);
    origin_.emplace(hostname_.view(), admission.target.port);
    head_.erase();
    state_ = State::establishing;
  }

  void connectOrigin(bool writable) noexcept {
    switch (origin_->advance(writable)) {
    case Origin::State::resolving:
    case Origin::State::connecting:
      return;
    case Origin::State::connected:
      successful_ = true;
      respond("HTTP/1.1 200 Connection Established\r\n\r\n");
      break;
    case Origin::State::failed:
      counters_.record(ProxyCounter::upstream_connect_failure);
      respond("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
      break;
    case Origin::State::resolution_refused:
      counters_.record(ProxyCounter::resolution_refusal);
      respond("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
      break;
    }

    if (origin_->truncated()) {
      counters_.record(ProxyCounter::resolution_truncated);
    }
  }

  void respond(std::string_view response) noexcept {
    response_ = response;
    state_ = State::replying;
  }

  void writeResponse(Time now) noexcept {
    const auto sent = ::send(child_.get(), response_.data(), response_.size(), 0);
    if (sent <= 0) {
      if (sent == 0 || !socketWouldBlock(errno)) {
        state_ = State::closed;
      }
      return;
    }

    response_.remove_prefix(static_cast<std::size_t>(sent));
    if (!response_.empty()) {
      return;
    }
    if (successful_) {
      state_ = State::established;
    } else if (drain_until_ > now) {
      ::shutdown(child_.get(), SHUT_WR);
      state_ = State::draining;
    } else {
      state_ = State::closed;
    }
  }

  void drain(Time now) noexcept {
    std::array<std::uint8_t, 4096> discarded;
    const auto received = ::recv(child_.get(), discarded.data(), discarded.size(), 0);
    if (received == 0 || (received < 0 && !socketWouldBlock(errno)) || now >= drain_until_) {
      state_ = State::closed;
    }
  }

  static constexpr auto refusal_drain = std::chrono::milliseconds{200};
  FileDescriptor child_;
  const ProxyOptions<Memory> &options_;
  const ProxySecret &secret_;
  ProxyCounters &counters_;
  FileDescriptor adopted_origin_;
  ConnectHead head_;
  AlpnOffer hello_;
  Time probe_until_{};
  Time probe_after_{};
  std::string_view failure_ = "connection_failed";
  bool inspected_ = false;
  FixedText<ProxyHostname::maximum_bytes> hostname_;
  std::optional<Origin> origin_;
  std::string_view response_;
  Time drain_until_{};
  State state_ = State::reading;
  bool successful_ = false;
  bool transparent_ = false;
};

}
