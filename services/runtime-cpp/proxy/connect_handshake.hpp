#pragma once

#include "../memory/fixed_text.hpp"
#include "authenticate.hpp"
#include "connect_head.hpp"
#include "connection_policy.hpp"
#include "counters.hpp"
#include "options.hpp"
#include "origin_connection.hpp"

namespace telar::runtime {

template <Allocator Memory, HostnameResolver Resolver>
class ConnectHandshake {
public:
  using Time = ProxyConnectionPolicy::Time;

  enum class State {
    reading,
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

  void advance(bool origin_writable, Time now) noexcept {
    TELAR_TRACE("proxy.connectHandshake");
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
    return state_ == State::draining ? std::optional{drain_until_} : std::nullopt;
  }

  int childDescriptor() const noexcept {
    return child_.get();
  }

  int originDescriptor() const noexcept {
    return origin_ ? origin_->descriptor() : -1;
  }

  std::size_t originAttempt() const noexcept {
    return origin_ ? origin_->attempt() : 0;
  }

  bool wantsChildRead() const noexcept {
    return state_ == State::reading || state_ == State::draining;
  }

  bool wantsChildWrite() const noexcept {
    return state_ == State::replying;
  }

  bool wantsOriginWrite() const noexcept {
    return state_ == State::establishing && origin_ && origin_->state() == Origin::State::connecting;
  }

  std::string_view hostname() const noexcept {
    return hostname_.view();
  }

  bool intercept() const noexcept {
    return options_.intercept_hosts.contains(hostname_.view());
  }

private:
  using Origin = OriginConnection<Resolver>;

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
  ConnectHead head_;
  FixedText<ProxyHostname::maximum_bytes> hostname_;
  std::optional<Origin> origin_;
  std::string_view response_;
  Time drain_until_{};
  State state_ = State::reading;
  bool successful_ = false;
};

}
