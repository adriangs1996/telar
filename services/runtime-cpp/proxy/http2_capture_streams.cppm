module;
#include "telar_platform/trace_macro.hpp"
#include <stdlib.h>
#include <memory>
#include <new>
#include <string>
#include <vector>

#include <concepts>
#include <cstdint>
#include <span>
#include <algorithm>
#include <cstring>
#include <string_view>
#include <cerrno>
#include <exception>
#include <csignal>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <cstddef>
#include <array>

#include <chrono>

#include <atomic>

#include <optional>
#include <arpa/inet.h>
#include <charconv>
#include <cstdlib>
#include <variant>
#include <pthread.h>
#include <netdb.h>
#include <type_traits>
#include <utility>

#include <brotli/decode.h>
#include <initializer_list>
#include <zlib.h>
#include <zstd.h>
#include <stdexcept>
#include <cassert>
#include <condition_variable>
#include <mutex>
#include <limits>
#include <bit>

export module telar.runtime.proxy.http2_capture_streams;

export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.proxy.relay_direction;
export import telar.base.memory;


export import telar.runtime.redirect.ingress;
export import telar.runtime.tls.interception;
export import telar.runtime.proxy.authenticate;


export import telar.config;


export import telar.runtime.http2.direction_observer;


export import telar.runtime.exchange_capture.pipeline;
export import telar.runtime.exchange_capture.producer;
export import telar.runtime.http1.head;
export import telar.runtime.http2.frame_reader;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: proxy/connect_head.cppm
export {
namespace telar::runtime {

class ConnectHead {
public:
  static constexpr std::size_t capacity = 16 * 1024;
  using Read = DelimitedRead::Result;

  inline Read receive(int socket) noexcept {
    SocketStream stream{socket};
    return reader_.receive(stream, storage_.bytes(), "\r\n\r\n");
  }

  inline std::string_view text() noexcept {
    return {reinterpret_cast<const char *>(storage_.bytes().data()), reader_.length()};
  }

  inline void erase() noexcept {
    eraseSensitive(storage_.bytes().data(), capacity);
    reader_.reset();
  }

private:
  SensitiveBuffer<capacity> storage_;
  DelimitedRead reader_;
};

}
}

// Interface: proxy/connection_policy.cppm
export {
namespace telar::runtime {

class ProxyConnectionPolicy {
public:
  using Clock = std::chrono::steady_clock;
  using Time = Clock::time_point;

  static constexpr std::size_t capacity = 256;
  static constexpr std::size_t maximum_unauthenticated = 64;
  static constexpr auto head_timeout = std::chrono::seconds{10};
  static constexpr auto establishment_timeout = std::chrono::seconds{30};
  static constexpr auto half_closed_timeout = std::chrono::seconds{60};
  static constexpr auto evictable_head_age = std::chrono::seconds{1};
  static constexpr auto evictable_idle_age = std::chrono::seconds{60};
  static constexpr auto evictable_silent_age = std::chrono::minutes{10};

  enum class Phase {
    connect_head,
    establishing,
    open,
    idle,
    half_closed,
    closing
  };

  enum class Closure {
    none,
    head_timeout,
    establishment_timeout,
    half_closed_timeout,
    evict_head,
    evict_idle,
    evict_silent
  };

  inline explicit ProxyConnectionPolicy(Time now) noexcept
      : since_(now),
        active_(now) {}

  inline void enter(Phase phase, Time now) noexcept {
    if (phase_ != phase) {
      phase_ = phase;
      since_ = now;
    }
  }

  inline void touch(Time now) noexcept {
    active_ = now;
  }

  inline void exchanges(std::uint32_t count) noexcept {
    exchanges_ = count;
  }

  inline Phase phase() const noexcept {
    return phase_;
  }

  inline Time since() const noexcept {
    return since_;
  }

  inline Time active() const noexcept {
    return active_;
  }

  inline Closure expired(Time now) const noexcept {
    switch (phase_) {
    case Phase::connect_head:
      return now - since_ >= head_timeout ? Closure::head_timeout : Closure::none;
    case Phase::establishing:
      return now - since_ >= establishment_timeout ? Closure::establishment_timeout : Closure::none;
    case Phase::half_closed:
      return now - active_ >= half_closed_timeout ? Closure::half_closed_timeout : Closure::none;
    default:
      return Closure::none;
    }
  }

  inline bool evictable(Closure reason, Time now) const noexcept {
    switch (reason) {
    case Closure::evict_head:
      return phase_ == Phase::connect_head && now - since_ >= evictable_head_age;
    case Closure::evict_idle:
      return phase_ == Phase::idle && exchanges_ == 0 && now - active_ >= evictable_idle_age;
    case Closure::evict_silent:
      return phase_ == Phase::open && exchanges_ == 0 && now - active_ >= evictable_silent_age;
    default:
      return false;
    }
  }

private:
  Phase phase_ = Phase::connect_head;
  Time since_;
  Time active_;
  std::uint32_t exchanges_ = 0;
};

}
}

// Interface: proxy/counters.cppm
export {
namespace telar::runtime {

enum class ProxyCounter : std::size_t {
  rejected_connection,
  invalid_authorization_rejection,
  unknown_credential_rejection,
  h2_decode_failure,
  passthrough_connection,
  anonymous_tunnel,
  upstream_connect_failure,
  tls_context_failure,
  tls_upstream_handshake_failure,
  tls_downstream_handshake_failure,
  tls_mint_failure,
  h2_capture_stream_skipped,
  http1_head_too_large,
  http1_chunk_line_too_long,
  http1_trailer_line_too_long,
  connect_head_too_large,
  connect_head_timeout,
  establish_timeout,
  eviction,
  unauthenticated_refusal,
  unauthenticated_eviction,
  h2_header_block_too_large,
  h2_stream_untracked,
  resolution_refusal,
  resolution_truncated,
  count
};

class ProxyCounters {
public:
  static constexpr auto capacity = static_cast<std::size_t>(ProxyCounter::count);
  static constexpr std::array<std::string_view, capacity> names = {
      "rejected_connection", "invalid_authorization_rejection", "unknown_credential_rejection",
      "h2_decode_failure", "passthrough_connection", "anonymous_tunnel", "upstream_connect_failure",
      "tls_context_failure", "tls_upstream_handshake_failure", "tls_downstream_handshake_failure",
      "tls_mint_failure", "h2_capture_stream_skipped", "http1_head_too_large", "http1_chunk_line_too_long",
      "http1_trailer_line_too_long", "connect_head_too_large", "connect_head_timeout", "establish_timeout",
      "eviction", "unauthenticated_refusal", "unauthenticated_eviction", "h2_header_block_too_large",
      "h2_stream_untracked", "resolution_refusal", "resolution_truncated"};

  inline void record(ProxyCounter counter, std::uint64_t count = 1) noexcept {
    counters_[static_cast<std::size_t>(counter)].fetch_add(count, std::memory_order_relaxed);
  }

  inline std::uint64_t read(ProxyCounter counter) const noexcept {
    return counters_[static_cast<std::size_t>(counter)].load(std::memory_order_relaxed);
  }

  inline std::array<std::uint64_t, capacity> snapshot() const noexcept {
    std::array<std::uint64_t, capacity> result;
    for (std::size_t index = 0; index != capacity; ++index) {
      result[index] = counters_[index].load(std::memory_order_relaxed);
    }

    return result;
  }

private:
  std::array<std::atomic<std::uint64_t>, capacity> counters_{};
};

}
}

// Interface: proxy/connect_handshake.cppm
export {
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

  inline explicit ConnectHandshake(FileDescriptor child, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters) noexcept
      : child_(std::move(child)),
        options_(options),
        secret_(secret),
        counters_(counters) {}

  inline explicit ConnectHandshake(redirect::Connection connection, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters) noexcept
      : child_(std::move(connection.child)), options_(options), secret_(secret), counters_(counters), adopted_origin_(std::move(connection.origin)), state_(State::established), transparent_(true) {
    hostname_.assign(connection.target.host.view());
    if (options_.transparent_tls) { state_ = State::probing; }
  }

  inline void advance(bool origin_writable, Time now) noexcept {
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

  inline void expire() noexcept {
    if (state_ == State::reading) {
      counters_.record(ProxyCounter::connect_head_timeout);
      state_ = State::closed;
    } else if (state_ == State::establishing) {
      counters_.record(ProxyCounter::establish_timeout);
      origin_.reset();
      respond("HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n");
    }
  }

  inline State state() const noexcept {
    return state_;
  }

  inline std::optional<Time> deadline() const noexcept {
    if (state_ == State::probing && probe_until_ != Time{}) { return std::min(probe_until_, probe_after_); }
    return state_ == State::draining ? std::optional{drain_until_} : std::nullopt;
  }

  inline int childDescriptor() const noexcept {
    return child_.get();
  }

  inline int originDescriptor() const noexcept {
    if (transparent_) {
      return adopted_origin_.get();
    }
    return origin_ ? origin_->descriptor() : -1;
  }

  inline std::size_t originAttempt() const noexcept {
    if (transparent_) {
      return 1;
    }
    return origin_ ? origin_->attempt() : 0;
  }

  inline bool wantsChildRead() const noexcept {
    return state_ == State::reading || state_ == State::draining || (state_ == State::probing && probe_after_ == Time{});
  }

  inline bool wantsChildWrite() const noexcept {
    return state_ == State::replying;
  }

  inline bool wantsOriginRead() const noexcept { return state_ == State::probing && !hello_.tls(); }

  inline std::string_view failure() const noexcept { return failure_; }

  inline bool wantsOriginWrite() const noexcept {
    return state_ == State::establishing && origin_ && origin_->state() == Origin::State::connecting;
  }

  inline std::string_view hostname() const noexcept {
    return hostname_.view();
  }

  inline bool intercept() const noexcept {
    return transparent_ ? inspected_ : options_.intercept_hosts.contains(hostname_.view());
  }

private:
  using Origin = OriginConnection<Resolver>;

  inline void probe(Time now) noexcept {
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

  inline void readHead(Time now) noexcept {
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

  inline void connectOrigin(bool writable) noexcept {
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

  inline void respond(std::string_view response) noexcept {
    response_ = response;
    state_ = State::replying;
  }

  inline void writeResponse(Time now) noexcept {
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

  inline void drain(Time now) noexcept {
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
}

// Interface: proxy/http2_capture_policy.cppm
export {
namespace telar::runtime {

template <typename Capture>
concept Http2CapturePolicy = requires(Capture &capture, Http2Direction direction, const Http2Event &event) {
  { capture.observe(direction, event) } noexcept -> std::same_as<void>;
  { capture.finish(direction) } noexcept -> std::same_as<void>;
};

struct IgnoreHttp2Capture {
  inline void observe(Http2Direction, const Http2Event &) noexcept {}
  inline void finish(Http2Direction) noexcept {}
};

static_assert(Http2CapturePolicy<IgnoreHttp2Capture>);

}
}

// Interface: proxy/http2_capture_streams.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http2CaptureStreams {
public:
  inline explicit Http2CaptureStreams(CaptureProducer<Memory> *producer, ProxyCounters &counters, CaptureStart context, CaptureSide side) noexcept
      : producer_(producer), counters_(counters), context_(context) {
    context_.side = side;
  }

  inline Http2CaptureStreams(Http2CaptureStreams &&other) noexcept
      : producer_(other.producer_), counters_(other.counters_), context_(other.context_), slots_(std::move(other.slots_)), occupied_(std::exchange(other.occupied_, {})) {}

  Http2CaptureStreams(const Http2CaptureStreams &) = delete;
  Http2CaptureStreams &operator=(const Http2CaptureStreams &) = delete;
  Http2CaptureStreams &operator=(Http2CaptureStreams &&) = delete;

  inline ~Http2CaptureStreams() { finish(); }

  inline void head(const Http2Event &event) noexcept {
    auto *half = ensure(event.stream);
    if (half == nullptr) {
      return;
    }

    const auto part = half->headPart();
    half->append(part, event.name);
    half->append(part, ": ");
    half->append(part, event.value);
    half->append(part, "\r\n");

    if (context_.side == CaptureSide::request) {
      if (event.name == ":method") {
        half->setMethod(event.value);
      } else if (event.name == ":path") {
        half->setTarget(event.value);
      }
    } else if (event.name == ":status") {
      const auto status = parseHttpNumber<10>(event.value);
      half->status_code = status && *status <= std::numeric_limits<std::uint16_t>::max() ? static_cast<std::uint16_t>(*status) : 0;
      if (half->status_code >= 100 && half->status_code < 200) {
        half->head.reset();
      }
    }

    if (asciiEqualIgnoreCase(event.name, "content-encoding")) {
      half->setEncoding(event.value);
    }
  }

  inline void body(const Http2Event &event) noexcept {
    if (const auto index = find(event.stream)) {
      auto &half = *slots_[*index];
      half->append(half->bodyPart(), event.bytes);
    }
  }

  inline void finish(std::uint32_t stream, CaptureOutcome outcome) noexcept {
    if (const auto index = find(stream)) {
      publish(*index, outcome);
    }
  }

  inline void finish() noexcept {
    occupied_.forEach([this](std::size_t index) { publish(index, CaptureOutcome::reset); });
  }

  static constexpr std::size_t capacity = Http2StreamTracker::capacity;

private:
  inline CaptureHalf<Memory> *ensure(std::uint32_t stream) noexcept {
    if (producer_ == nullptr) {
      return nullptr;
    }
    if (const auto existing = find(stream)) {
      return slots_[*existing]->get();
    }

    const auto index = occupied_.firstUnused();
    if (!index) {
      counters_.record(ProxyCounter::h2_capture_stream_skipped);
      return nullptr;
    }

    context_.key.stream = stream;
    context_.started_at_ms = Clock::now();
    auto half = producer_->start(context_);
    if (!half) {
      return nullptr;
    }

    slots_[*index].emplace(std::move(half));
    occupied_.insert(*index);
    return slots_[*index]->get();
  }

  inline std::optional<std::size_t> find(std::uint32_t stream) const noexcept {
    std::optional<std::size_t> found;
    occupied_.forEach([&](std::size_t index) {
      if ((*slots_[index])->key.stream == stream) {
        found = index;
      }
    });
    return found;
  }

  inline void publish(std::size_t index, CaptureOutcome outcome) noexcept {
    auto half = std::move(*slots_[index]);
    slots_[index].reset();
    occupied_.erase(index);
    half->finish(outcome, Clock::now());
    producer_->publish(std::move(half));
  }

  CaptureProducer<Memory> *producer_;
  ProxyCounters &counters_;
  CaptureStart context_;
  std::array<std::optional<typename CaptureProducer<Memory>::Half>, capacity> slots_;
  SlotIndexes<capacity> occupied_;
};

}
}

// Interface: proxy/metrics.cppm
export {
namespace telar::runtime {

struct ProxyMetrics {
  std::array<std::uint64_t, ProxyCounters::capacity> counters{};
  std::uint32_t active_connections = 0;
  std::uint64_t connection_limit_drops = 0;

  inline std::uint64_t read(ProxyCounter counter) const noexcept {
    return counters[static_cast<std::size_t>(counter)];
  }
};

}
}
