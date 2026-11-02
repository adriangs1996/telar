#pragma once

#include "../tls/interception.hpp"
#include "../tls/stream.hpp"
#include "application_relay.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsTunnel {
public:
  explicit TlsTunnel(Memory &memory, const TlsInterception<Memory> &interception, TunnelSockets sockets, std::string_view hostname, ConnectionObservation<Memory> observation, FlowState *flow = nullptr)
      : flow_(flow),
        observation_(observation),
        session_(interception.open(memory, sockets, hostname)),
        application_(memory, observation, hostname, flow) {}

  auto advance(TunnelReadiness readiness) noexcept -> bool {
    if (failed_) {
      return false;
    }

    if (!established()) {
      if (session_->advance() == TlsSession<Memory>::State::failed) {
        const auto reason = recordFailure();

        if (flow_ != nullptr) {
          flow_->error(reason);
        }

        failed_ = true;
        return false;
      }

      if (!established()) {
        return false;
      }

      if (flow_ != nullptr) {
        flow_->visibility(traffic::Visibility::plaintext);
      }

      readiness = TunnelReadiness::available();
    }

    TlsStream child{*session_, TlsSide::child};
    TlsStream origin{*session_, TlsSide::origin};
    readiness.child.readable = readiness.child.readable || session_->buffered(TlsSide::child);
    readiness.origin.readable = readiness.origin.readable || session_->buffered(TlsSide::origin);
    application_.select(session_->protocol(), session_->unnegotiated());

    return application_.advance(child, origin, readiness);
  }

  auto deadline() const noexcept {
    const auto session = session_->deadline();
    const auto application = application_.deadline();
    return session && application ? std::optional{std::min(*session, *application)} : session ? session
                                                                                              : application;
  }

  [[nodiscard]] auto established() const noexcept -> bool {
    return session_->state() == TlsSession<Memory>::State::established;
  }

  [[nodiscard]] auto finished() const noexcept -> bool {
    return failed_ || application_.finished();
  }

  [[nodiscard]] auto halfClosed() const noexcept -> bool {
    return application_.halfClosed();
  }

  [[nodiscard]] auto idle() const noexcept -> bool {
    return application_.idle();
  }

  [[nodiscard]] auto inflight() const noexcept -> std::uint32_t {
    return application_.inflight();
  }

  [[nodiscard]] auto buffered() const noexcept -> bool {
    return application_.buffered() || (application_.readsChild() && session_->buffered(TlsSide::child)) || (application_.readsOrigin() && session_->buffered(TlsSide::origin));
  }

  [[nodiscard]] auto interest(TlsSide side) const noexcept -> SocketInterest {
    if (established()) {
      return application_.interest(side);
    }

    SocketInterest interest;
    interest.include(session_->waiting(side));
    return interest;
  }

private:
  std::string_view recordFailure() noexcept {
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

  FlowState *flow_;
  ConnectionObservation<Memory> observation_;
  Owned<TlsSession<Memory>, Memory> session_;
  ApplicationRelay<Memory> application_;
  bool failed_ = false;
};

}
