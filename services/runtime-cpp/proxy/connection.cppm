module;

#include <cstddef>
#include <string_view>
#include <limits>
#include <optional>
#include <cstdint>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <span>
#include <utility>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>
#include <array>
#include <memory>
#include <stdexcept>
#include <zstd.h>
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include <charconv>
#include <chrono>
#include <concepts>
#include <algorithm>
#include <cerrno>
#include <exception>
#include <csignal>
#include <sys/socket.h>
#include "telar_platform/file_descriptor.hpp"
#include <netinet/in.h>
#include <netinet/tcp.h>
#include "telar_base/memory/fixed_text.hpp"
#include <arpa/inet.h>
#include <initializer_list>
#include "telar_platform/trace.hpp"
#include <atomic>
#include <cassert>
#include <condition_variable>
#include <mutex>
#include <type_traits>
#include <unistd.h>
#include <cstdio>
#include <netdb.h>
#include <nghttp2/nghttp2.h>


#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/crypto.h>
#include <ctime>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include "telar_platform/random_bytes.hpp"
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <cstdlib>


#include "telar_base/text/base64.hpp"
#include <variant>
#include <pthread.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif


#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

export module telar.runtime.proxy.connection;

export import telar.runtime.proxy.application_relay;
export import telar.runtime.platform.launch_program;


export import telar.runtime.tls.interception;


export import telar.runtime.proxy.http2_capture_streams;

// Interface: proxy/plain_tunnel.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class PlainTunnel {
public:
  inline explicit PlainTunnel(Memory &memory, TunnelSockets sockets, std::string_view hostname, ConnectionObservation<Memory> observation, FlowState *flow) : sockets_(sockets), application_(memory, observation, hostname, flow) {}

  inline bool advance(TunnelReadiness readiness) noexcept {
    SocketStream child{sockets_.child}, origin{sockets_.origin};
    return application_.advance(child, origin, readiness);
  }
  inline bool finished() const noexcept { return application_.finished(); }
  inline bool halfClosed() const noexcept { return application_.halfClosed(); }
  inline bool idle() const noexcept { return application_.idle(); }
  inline std::uint32_t inflight() const noexcept { return application_.inflight(); }
  inline bool buffered() const noexcept { return application_.buffered(); }
  inline auto deadline() const noexcept { return application_.deadline(); }
  inline SocketInterest interest(TlsSide side) const noexcept { return application_.interest(side); }
private:
  TunnelSockets sockets_;
  ApplicationRelay<Memory> application_;
};

}
}

// Interface: proxy/tls_tunnel.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsTunnel {
public:
  inline explicit TlsTunnel(Memory &memory, const TlsInterception<Memory> &interception, TunnelSockets sockets, std::string_view hostname, ConnectionObservation<Memory> observation, FlowState *flow = nullptr)
      : flow_(flow),
        observation_(observation),
        session_(interception.open(memory, sockets, hostname)),
        application_(memory, observation, hostname, flow) {}

  inline auto advance(TunnelReadiness readiness) noexcept -> bool {
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

  inline auto deadline() const noexcept {
    const auto session = session_->deadline();
    const auto application = application_.deadline();
    return session && application ? std::optional{std::min(*session, *application)} : session ? session
                                                                                              : application;
  }

  [[nodiscard]] inline auto established() const noexcept -> bool {
    return session_->state() == TlsSession<Memory>::State::established;
  }

  [[nodiscard]] inline auto finished() const noexcept -> bool {
    return failed_ || application_.finished();
  }

  [[nodiscard]] inline auto halfClosed() const noexcept -> bool {
    return application_.halfClosed();
  }

  [[nodiscard]] inline auto idle() const noexcept -> bool {
    return application_.idle();
  }

  [[nodiscard]] inline auto inflight() const noexcept -> std::uint32_t {
    return application_.inflight();
  }

  [[nodiscard]] inline auto buffered() const noexcept -> bool {
    return application_.buffered() || (application_.readsChild() && session_->buffered(TlsSide::child)) || (application_.readsOrigin() && session_->buffered(TlsSide::origin));
  }

  [[nodiscard]] inline auto interest(TlsSide side) const noexcept -> SocketInterest {
    if (established()) {
      return application_.interest(side);
    }

    SocketInterest interest;
    interest.include(session_->waiting(side));
    return interest;
  }

private:
  inline std::string_view recordFailure() noexcept {
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
}

// Interface: proxy/connection_transport.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ConnectionTransport {
public:
  inline explicit ConnectionTransport(Memory &memory) noexcept
      : memory_(memory), flow_(nullptr, AllocationDeleter<FlowState, Memory>{memory}), plain_(nullptr, AllocationDeleter<PlainTunnel<Memory>, Memory>{memory}), tls_(nullptr, AllocationDeleter<TlsTunnel<Memory>, Memory>{memory}) {}

  template <HostnameResolver Resolver>
  inline void open(const TlsInterception<Memory> &interception, const ConnectHandshake<Memory, Resolver> &handshake, ConnectionObservation<Memory> observation) {
    if (observation.flows) {
      flow_ = makeOwned<FlowState>(memory_);
      flow_->open(observation.flows, observation.identity, handshake.childDescriptor(), handshake.originDescriptor(), handshake.hostname());
    }
    const TunnelSockets sockets{handshake.childDescriptor(), handshake.originDescriptor()};
    if (handshake.intercept()) {
      tls_ = makeOwned<TlsTunnel<Memory>>(memory_, memory_, interception, sockets, handshake.hostname(), observation, flow_.get());
    } else {
      plain_ = makeOwned<PlainTunnel<Memory>>(memory_, memory_, sockets, handshake.hostname(), observation, flow_.get());
      observation.counters.record(ProxyCounter::passthrough_connection);
    }
  }

  inline bool opened() const noexcept { return plain_ || tls_; }

  inline bool advance(TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.relayTunnel");
    return plain_ ? plain_->advance(readiness) : tls_->advance(readiness);
  }

  inline bool established() const noexcept { return plain_ || tls_->established(); }
  inline bool finished() const noexcept { return (flow_ && flow_->rejected()) || (plain_ ? plain_->finished() : tls_->finished()); }
  inline bool halfClosed() const noexcept { return plain_ ? plain_->halfClosed() : tls_->halfClosed(); }
  inline bool idle() const noexcept { return plain_ ? plain_->idle() : tls_ && tls_->idle(); }
  inline std::uint32_t inflight() const noexcept { return plain_ ? plain_->inflight() : tls_ ? tls_->inflight() : 0; }
  inline bool buffered() const noexcept { return plain_ ? plain_->buffered() : tls_ && tls_->buffered(); }

  inline SocketInterest interest(TlsSide side) const noexcept {
    if (plain_) {
      return plain_->interest(side);
    }
    return tls_->interest(side);
  }

  inline std::optional<traffic::FlowControl::Time> deadline() const noexcept {
    const auto flow = flow_ ? flow_->deadline() : std::nullopt;
    const auto tls = plain_ ? plain_->deadline() : tls_ ? tls_->deadline() : std::nullopt;
    return flow && tls ? std::min(*flow, *tls) : flow ? flow : tls;
  }
  inline void reason(std::string_view value) noexcept { if (flow_) { flow_->reason(value); } }
  inline void error(std::string_view value) noexcept { if (flow_) { flow_->error(value); } }

private:
  Memory &memory_;
  Owned<FlowState, Memory> flow_;
  Owned<PlainTunnel<Memory>, Memory> plain_;
  Owned<TlsTunnel<Memory>, Memory> tls_;
};

}
}

// Interface: proxy/observations.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ProxyObservations {
public:
  inline explicit ProxyObservations(Memory &memory, ProxyCaptureLimits limits, traffic::FlowControl *flows = nullptr) : captures(memory, limits), capture_enabled_(limits.enabled), flows_(flows) {}

  inline ConnectionObservation<Memory> connection() noexcept {
    return {counters, capture_enabled_ ? &captures : nullptr, next_connection_++, flows_};
  }

  ProxyCounters counters;
  CaptureProducer<Memory> captures;

private:
  bool capture_enabled_;
  traffic::FlowControl *flows_;
  std::uint64_t next_connection_ = 1;
};

}
}

// Interface: proxy/connection.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, HostnameResolver Resolver>
class ProxyConnection {
public:
  using Time = ProxyConnectionPolicy::Time;

  inline explicit ProxyConnection(Memory &memory, FileDescriptor child, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters)
      : counters_(counters), handshake_(std::move(child), options, secret, counters), transport_(memory), policy_(ProxyConnectionPolicy::Clock::now()) {}

  inline explicit ProxyConnection(Memory &memory, redirect::Connection connection, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters)
      : counters_(counters), redirect_lifetime_(std::move(connection.lifetime)), handshake_(std::move(connection), options, secret, counters), transport_(memory), policy_(ProxyConnectionPolicy::Clock::now()) {}

  inline void advance(const TlsInterception<Memory> &interception, ProxyObservations<Memory> &observations, TunnelReadiness readiness, Time now) noexcept {
    if (closed_) {
      return;
    }
    if (!transport_.opened()) {
      handshake_.advance(readiness.origin.writable, now);
      if (!observation_ && !handshake_.hostname().empty()) {
        observation_.emplace(observations.connection());
      }
      if (handshake_.state() == Handshake::State::closed) {
        if (observation_ && observation_->flows) {
          observation_->flows->observeFlow(traffic::Kind::flow_error, {.id = observation_->identity, .host = handshake_.hostname(), .reason = handshake_.failure()});
        }
        closed_ = true;
        return;
      }
      if (handshake_.state() != Handshake::State::reading && policy_.phase() == Phase::connect_head) {
        enter(Phase::establishing, now);
      }
      if (handshake_.state() != Handshake::State::established) {
        return;
      }
      try {
        transport_.open(interception, handshake_, *observation_);
        readiness = TunnelReadiness::available();
      } catch (...) {
        if (handshake_.intercept()) {
          counters_.record(ProxyCounter::tls_context_failure);
        }
        transport_.error(handshake_.intercept() ? "tls_context_failed" : "transport_setup_failed");
        closed_ = true;
        return;
      }
    }

    if (transport_.advance(readiness)) {
      policy_.touch(now);
    }
    policy_.exchanges(transport_.inflight());
    if (transport_.finished()) {
      closed_ = true;
    } else if (transport_.halfClosed()) {
      enter(Phase::half_closed, now);
    } else if (transport_.established()) {
      enter(transport_.idle() ? Phase::idle : Phase::open, now);
    }
  }

  inline void expire(Time now) noexcept {
    using Closure = ProxyConnectionPolicy::Closure;
    const auto closure = policy_.expired(now);
    if (closure != Closure::none) { transport_.reason("timeout"); }
    switch (closure) {
    case Closure::head_timeout:
      handshake_.expire();
      closed_ = true;
      break;
    case Closure::establishment_timeout:
      if (transport_.opened() || handshake_.state() != Handshake::State::establishing) {
        counters_.record(ProxyCounter::establish_timeout);
        closed_ = true;
      } else {
        handshake_.expire();
        enter(Phase::closing, now);
      }
      break;
    case Closure::half_closed_timeout:
      closed_ = true;
      break;
    default:
      break;
    }
  }

  inline SocketInterest interest(TlsSide side) const noexcept {
    if (transport_.opened()) {
      return transport_.interest(side);
    }
    if (side == TlsSide::child) {
      return {.readable = handshake_.wantsChildRead(), .writable = handshake_.wantsChildWrite()};
    }
    return {.readable = handshake_.wantsOriginRead(), .writable = handshake_.wantsOriginWrite()};
  }

  inline int descriptor(TlsSide side) const noexcept {
    return side == TlsSide::child ? handshake_.childDescriptor() : handshake_.originDescriptor();
  }

  inline std::size_t originAttempt() const noexcept {
    return handshake_.originAttempt();
  }

  inline bool closed() const noexcept {
    return closed_;
  }

  inline bool buffered() const noexcept {
    return transport_.buffered();
  }

  inline std::optional<Time> deadline() const noexcept {
    const auto handshake = handshake_.deadline();
    const auto transport = transport_.deadline();
    return handshake && transport ? std::min(*handshake, *transport) : handshake ? handshake : transport;
  }

  inline const ProxyConnectionPolicy &policy() const noexcept {
    return policy_;
  }

private:
  using Handshake = ConnectHandshake<Memory, Resolver>;
  using Phase = ProxyConnectionPolicy::Phase;

  inline void enter(Phase phase, Time now) noexcept {
    if (policy_.phase() != phase) {
      policy_.enter(phase, now);
      policy_.touch(now);
    }
  }

  ProxyCounters &counters_;
  FileDescriptor redirect_lifetime_;
  Handshake handshake_;
  ConnectionTransport<Memory> transport_;
  ProxyConnectionPolicy policy_;
  std::optional<ConnectionObservation<Memory>> observation_;
  bool closed_ = false;
};

}
}
