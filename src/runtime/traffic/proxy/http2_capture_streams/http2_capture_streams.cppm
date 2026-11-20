module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.traffic.proxy.http2_capture_streams;

import std;
import telar.sys.socket;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.platform.stream_read_buffer;
import telar.runtime.traffic.proxy.relay_direction;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;

import telar.runtime.traffic.redirect.ingress;
import telar.runtime.traffic.tls.interception;
import telar.runtime.traffic.proxy.authenticate;

import telar.config.runtime;

import telar.runtime.traffic.http2.direction_observer;

import telar.runtime.traffic.exchange_capture.pipeline;
import telar.runtime.traffic.exchange_capture.producer;
import telar.runtime.traffic.http2.frame_reader;
import telar.platform.primitives;
import telar.runtime.traffic.http1.head;
import telar.base.text;
import telar.platform.net;
import telar.runtime.traffic.tap.exchange;
import telar.runtime.platform.name_resolutions;
import telar.base.ds;

// Interface: proxy/responses.cppm
export {
  namespace telar::runtime::proxy_responses {

    // The answers the proxy writes itself, byte for byte as clients have always received them.
    inline constexpr std::string_view connection_established = "HTTP/1.1 200 Connection Established\r\n\r\n";
    inline constexpr std::string_view head_too_large = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    inline constexpr std::string_view bad_gateway = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n";
    inline constexpr std::string_view bad_gateway_closing = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    inline constexpr std::string_view service_unavailable = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n";
    inline constexpr std::string_view service_unavailable_closing = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    inline constexpr std::string_view gateway_timeout = "HTTP/1.1 504 Gateway Timeout\r\nContent-Length: 0\r\n\r\n";

  }
}

// Interface: proxy/connect_head.cppm
export {
  namespace telar::runtime {

    class ConnectHead {
    public:
      static constexpr std::size_t capacity = std::size_t{16} * 1024;
      using Read = DelimitedRead::Result;

      // The storage is written before it is read: allocating a head does not zero 16 KiB.
      ConnectHead() noexcept;

      Read receive(int socket) noexcept;

      std::string_view text() noexcept;

      void erase() noexcept;

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

      enum class Phase : std::uint8_t {
        connect_head,
        establishing,
        open,
        idle,
        half_closed,
        closing,
      };

      enum class Closure : std::uint8_t {
        none,
        head_timeout,
        establishment_timeout,
        half_closed_timeout,
        evict_head,
        evict_idle,
        evict_silent,
      };

      explicit ProxyConnectionPolicy(Time now) noexcept;

      void enter(Phase phase, Time now) noexcept;

      void touch(Time now) noexcept;

      void exchanges(std::uint32_t count) noexcept;

      [[nodiscard]] Phase phase() const noexcept;

      [[nodiscard]] Time since() const noexcept;

      [[nodiscard]] Time active() const noexcept;

      [[nodiscard]] Closure expired(Time now) const noexcept;

      [[nodiscard]] bool evictable(Closure reason, Time now) const noexcept;

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

    enum class ProxyCounter : std::uint8_t {
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
      count,
    };

    // Every counter is atomic, so a reference to them stays valid whatever any thread records.
    class TBC_SHARED ProxyCounters {
    public:
      static constexpr auto capacity = static_cast<std::size_t>(ProxyCounter::count);
      static constexpr ds::Array<std::string_view, capacity> names = {
          "rejected_connection",
          "invalid_authorization_rejection",
          "unknown_credential_rejection",
          "h2_decode_failure",
          "passthrough_connection",
          "anonymous_tunnel",
          "upstream_connect_failure",
          "tls_context_failure",
          "tls_upstream_handshake_failure",
          "tls_downstream_handshake_failure",
          "tls_mint_failure",
          "h2_capture_stream_skipped",
          "http1_head_too_large",
          "http1_chunk_line_too_long",
          "http1_trailer_line_too_long",
          "connect_head_too_large",
          "connect_head_timeout",
          "establish_timeout",
          "eviction",
          "unauthenticated_refusal",
          "unauthenticated_eviction",
          "h2_header_block_too_large",
          "h2_stream_untracked",
          "resolution_refusal",
          "resolution_truncated",
      };

      void record(ProxyCounter counter, std::uint64_t count = 1) noexcept;

      std::uint64_t read(ProxyCounter counter) const noexcept;

      ds::Array<std::uint64_t, capacity> snapshot() const noexcept;

    private:
      ds::Array<std::atomic<std::uint64_t>, capacity> counters_{};
    };

  }
}

// Interface: proxy/connect_handshake.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's resolver.
    template <Allocator Memory, HostnameResolver Resolver>
    class TBC_GENERIC ConnectHandshake {
    public:
      using Time = ProxyConnectionPolicy::Time;

      enum class State : std::uint8_t {
        reading,
        probing,
        establishing,
        replying,
        draining,
        established,
        closed,
      };

      // A CONNECT handshake reads the request head into storage from `memory`, released once the head
      // is answered.
      inline explicit ConnectHandshake(Memory& memory, FileDescriptor child, const ProxyOptions<Memory>& options, const ProxySecret& secret, ProxyCounters& counters)
          : child_(std::move(child)),
            options_(options),
            secret_(secret),
            counters_(counters),
            head_(ds::makeBox<ConnectHead>(memory)),
            hello_() {}

      // A redirected connection reads the ClientHello only when transparent TLS may intercept it, into
      // an offer from `memory` that the TLS session takes over or that is released once established.
      inline explicit ConnectHandshake(Memory& memory, redirect::Connection connection, const ProxyOptions<Memory>& options, const ProxySecret& secret, ProxyCounters& counters)
          : child_(std::move(connection.child)),
            options_(options),
            secret_(secret),
            counters_(counters),
            adopted_origin_(std::move(connection.origin)),
            head_(),
            hello_(),
            state_(State::established),
            transparent_(true) {
        hostname_.assign(connection.target.host.view());
        if (options_.transparent_tls) {
          hello_ = ds::makeBox<AlpnOffer>(memory);
          state_ = State::probing;
        }
      }

      // The child's ClientHello, read complete, when the connection is to be intercepted; null
      // otherwise. The handshake keeps no part of it.
      inline ds::Box<AlpnOffer, Memory> takeOffer() noexcept {
        return std::move(hello_);
      }

      // Not inlined: ProxyConnection::advance runs on every event of a connection and calls it only until
      // the CONNECT is answered; its locals in that frame would put every relayed event on deeper stack pages.
      [[gnu::noinline]] inline void advance(bool origin_writable, Time now) noexcept {
        TELAR_TRACE("proxy.connectHandshake");
        if (state_ == State::probing) {
          probe(now);
        }

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
          respond(proxy_responses::gateway_timeout);
        }
      }

      inline State state() const noexcept {
        return state_;
      }

      [[nodiscard]] inline ds::Option<Time> deadline() const noexcept {
        if (state_ == State::probing && probe_until_ != Time{}) {
          return std::min(probe_until_, probe_after_);
        }

        return state_ == State::draining ? ds::Option{drain_until_} : ds::none;
      }

      [[nodiscard]] inline int childDescriptor() const noexcept {
        return child_.get();
      }

      [[nodiscard]] inline int originDescriptor() const noexcept {
        if (transparent_) {
          return adopted_origin_.get();
        }

        return origin_ ? origin_->descriptor() : -1;
      }

      [[nodiscard]] inline std::size_t originAttempt() const noexcept {
        if (transparent_) {
          return 1;
        }

        return origin_ ? origin_->attempt() : 0;
      }

      [[nodiscard]] inline bool wantsChildRead() const noexcept {
        return state_ == State::reading || state_ == State::draining || (state_ == State::probing && probe_after_ == Time{});
      }

      [[nodiscard]] inline bool wantsChildWrite() const noexcept {
        return state_ == State::replying;
      }

      [[nodiscard]] inline bool wantsOriginRead() const noexcept {
        return state_ == State::probing && !hello_->tls();
      }

      [[nodiscard]] inline std::string_view failure() const noexcept {
        return failure_;
      }

      [[nodiscard]] inline bool wantsOriginWrite() const noexcept {
        return state_ == State::establishing && origin_ && origin_->state() == Origin::State::connecting;
      }

      [[nodiscard]] inline std::string_view hostname() const noexcept {
        return hostname_.view();
      }

      [[nodiscard]] inline bool intercept() const noexcept {
        return transparent_ ? inspected_ : options_.intercept_hosts.contains(hostname_.view());
      }

    private:
      using Origin = OriginConnection<Resolver>;

      inline void probe(Time now) noexcept {
        inspect(now);
        // Only an intercepted connection hands its ClientHello on.
        if (state_ != State::probing && !(state_ == State::established && inspected_)) {
          hello_.reset();
        }
      }

      inline void inspect(Time now) noexcept {
        if (!hello_->tls()) {
          std::uint8_t byte = 0;
          const auto count = ::recv(adopted_origin_.get(), &byte, 1, MSG_PEEK);
          if (count > 0) {
            state_ = State::established;
            return;
          }

          if (count == 0 || (count < 0 && !socketWouldBlock(sys::lastError()))) {
            state_ = State::closed;
            failure_ = "origin_closed_before_client_hello";
            return;
          }
        }

        if (probe_until_ == Time{}) {
          probe_until_ = now + std::chrono::seconds{3};
        }

        if (now < probe_after_) {
          return;
        }

        const auto read = hello_.getMut().peek(child_.get());
        if (read == AlpnOffer::Read::pending) {
          if (now >= probe_until_) {
            state_ = hello_->tls() ? State::closed : State::established;
            failure_ = "tls_client_hello_timeout";
          }

          probe_after_ = now + std::chrono::milliseconds{2};
          return;
        }

        if (read == AlpnOffer::Read::ended) {
          state_ = State::closed;
          return;
        }

        if (!hello_->tls()) {
          state_ = State::established;
          return;
        }

        const auto name = hello_->serverName();
        const auto host = name.empty() ? hostname_.view() : name;

        inspected_ = options_.intercept_hosts.contains(host);
        if (inspected_ && (!hello_->valid() || hello_->encrypted())) {
          failure_ = hello_->encrypted() ? "tls_ech_not_supported" : "tls_client_hello_invalid";
          state_ = State::closed;
          return;
        }

        if (inspected_ && !name.empty()) {
          hostname_.assign(name);
        }

        state_ = State::established;
      }

      inline void readHead(Time now) noexcept {
        switch (head_.getMut().receive(child_.get())) {
        case ConnectHead::Read::pending:
          return;
        case ConnectHead::Read::ended:
          state_ = State::closed;
          head_.reset();
          return;
        case ConnectHead::Read::too_large:
          counters_.record(ProxyCounter::connect_head_too_large);
          head_.reset();
          drain_until_ = now + refusal_drain;
          respond(proxy_responses::head_too_large);
          return;
        case ConnectHead::Read::complete:
          break;
        }

        const auto decision = authenticateProxy(secret_, options_.anonymous_tunnels, options_.intercept_hosts, head_.getMut().text());
        if (const auto* rejected = std::get_if<ProxyRejection>(&decision)) {
          if (rejected->reason != ProxyRejection::Reason::invalid_target) {
            counters_.record(ProxyCounter::rejected_connection);
            counters_.record(rejected->reason == ProxyRejection::Reason::unknown_credential ? ProxyCounter::unknown_credential_rejection : ProxyCounter::invalid_authorization_rejection);
          }

          respond(rejected->response());
          head_.reset();
          return;
        }

        const auto& admission = std::get<ProxyAdmission>(decision);
        if (!admission.authenticated) {
          counters_.record(ProxyCounter::anonymous_tunnel);
        }

        hostname_.assign(admission.target.hostname);
        origin_.emplace(hostname_.view(), admission.target.port);
        head_.reset();
        state_ = State::establishing;
      }

      inline void connectOrigin(bool writable) noexcept {
        switch (origin_.getMut().advance(writable)) {
        case Origin::State::resolving:
        case Origin::State::connecting:
          return;
        case Origin::State::connected:
          successful_ = true;
          respond(proxy_responses::connection_established);
          break;
        case Origin::State::failed:
          counters_.record(ProxyCounter::upstream_connect_failure);
          respond(proxy_responses::bad_gateway);
          break;
        case Origin::State::resolution_refused:
          counters_.record(ProxyCounter::resolution_refusal);
          respond(proxy_responses::service_unavailable);
          break;
        }

        if (origin_->truncated()) {
          counters_.record(ProxyCounter::resolution_truncated);
        }
      }

      inline void respond(tbc::val_static<std::string_view> response) noexcept {
        response_ = StaticReply{response};
        state_ = State::replying;
      }

      inline void writeResponse(Time now) noexcept {
        SocketStream stream{child_.get()};
        const auto sent = response_.write(stream);
        if (sent.state != StreamResult::State::data) {
          if (sent.state != StreamResult::State::blocked) {
            state_ = State::closed;
          }

          return;
        }

        if (!response_.sent()) {
          return;
        }

        if (successful_) {
          state_ = State::established;
        } else if (drain_until_ > now) {
          stream.halfClose();
          state_ = State::draining;
        } else {
          state_ = State::closed;
        }
      }

      inline void drain(Time now) noexcept {
        SocketStream stream{child_.get()};
        if (drainEnded(stream) || now >= drain_until_) {
          state_ = State::closed;
        }
      }

      static constexpr auto refusal_drain = std::chrono::milliseconds{200};
      FileDescriptor child_;
      const ProxyOptions<Memory>& options_;
      const ProxySecret& secret_;
      ProxyCounters& counters_;
      FileDescriptor adopted_origin_;
      // The CONNECT head until it is answered, and the ClientHello of a redirected connection until
      // the handshake is established.
      ds::Box<ConnectHead, Memory> head_;
      ds::Box<AlpnOffer, Memory> hello_;
      Time probe_until_;
      Time probe_after_;
      std::string_view failure_ = "connection_failed";
      bool inspected_ = false;
      FixedText<ProxyHostname::maximum_bytes> hostname_;
      ds::Option<Origin> origin_;
      StaticReply response_;
      Time drain_until_;
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
    concept Http2CapturePolicy = requires(Capture& capture, Http2Direction direction, const Http2Event& event) {
      { capture.observe(direction, event) } noexcept -> std::same_as<void>;
      { capture.finish(direction) } noexcept -> std::same_as<void>;
    };

    struct IgnoreHttp2Capture {
      constexpr void observe(Http2Direction /*direction*/, const Http2Event& /*event*/) noexcept {}

      constexpr void finish(Http2Direction /*direction*/) noexcept {}
    };

    static_assert(Http2CapturePolicy<IgnoreHttp2Capture>);

  }
}

// Interface: proxy/http2_capture_streams.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's clock.
    template <CaptureClock Clock = CaptureWallClock>
    class TBC_GENERIC Http2CaptureStreams {
    public:
      inline explicit Http2CaptureStreams(CaptureProducer* producer, ProxyCounters& counters, CaptureStart context, CaptureSide side) noexcept
          : producer_(producer),
            counters_(counters),
            context_(std::move(context)) {
        context_.side = side;
      }

      inline Http2CaptureStreams(Http2CaptureStreams&& other) noexcept
          : producer_(other.producer_),
            counters_(other.counters_),
            context_(std::move(other.context_)),
            slots_(std::move(other.slots_)),
            occupied_(std::exchange(other.occupied_, {})) {}

      Http2CaptureStreams(const Http2CaptureStreams&) = delete;
      Http2CaptureStreams& operator=(const Http2CaptureStreams&) = delete;
      Http2CaptureStreams& operator=(Http2CaptureStreams&&) = delete;

      inline ~Http2CaptureStreams() {
        finish();
      }

      inline void head(const Http2Event& event) noexcept {
        auto* half = ensure(event.stream);
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
          // An informational (1xx) response precedes the final one, whose head replaces it.
          constexpr std::uint16_t first_informational_status = 100;
          constexpr std::uint16_t first_successful_status = 200;

          half->status_code = parseHttpStatus(event.value).valueOr(0);
          if (half->status_code >= first_informational_status && half->status_code < first_successful_status) {
            half->head.reset();
          }
        }

        if (asciiEqualIgnoreCase(event.name, "content-encoding")) {
          half->setEncoding(event.value);
        }
      }

      inline void body(const Http2Event& event) noexcept {
        if (const auto index = find(event.stream)) {
          auto& half = slots_.atMut(*index).getMut();

          half.getMut().append(half->bodyPart(), event.bytes);
        }
      }

      inline void finish(std::uint32_t stream, CaptureOutcome outcome) noexcept {
        if (const auto index = find(stream)) {
          publish(*index, outcome);
        }
      }

      inline void finish() noexcept {
        occupied_.forEach([this](std::size_t index) {
          publish(index, CaptureOutcome::reset);
        });
      }

      static constexpr std::size_t capacity = Http2StreamTracker::capacity;

    private:
      inline CaptureHalf* ensure(std::uint32_t stream) noexcept {
        if (producer_ == nullptr) {
          return nullptr;
        }

        if (const auto existing = find(stream)) {
          return &slots_.atMut(*existing).getMut().getMut();
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

        slots_.atMut(*index).emplace(std::move(half));
        occupied_.insert(*index);
        return &slots_.atMut(*index).getMut().getMut();
      }

      [[nodiscard]] inline ds::Option<std::size_t> find(std::uint32_t stream) const noexcept {
        ds::Option<std::size_t> found;

        occupied_.forEach([&](std::size_t index) {
          if ((*slots_[index])->key.stream == stream) {
            found = index;
          }
        });

        return found;
      }

      inline void publish(std::size_t index, CaptureOutcome outcome) noexcept {
        auto half = std::move(slots_.atMut(index).getMut());

        slots_.atMut(index).reset();
        occupied_.erase(index);
        half.getMut().finish(outcome, Clock::now());
        producer_->publish(std::move(half));
      }

      CaptureProducer* producer_;
      ProxyCounters& counters_;
      CaptureStart context_;
      ds::Array<ds::Option<CaptureProducer::Half>, capacity> slots_;
      SlotIndexes<capacity> occupied_;
    };

  }
}

// Interface: proxy/metrics.cppm
export {
  namespace telar::runtime {

    struct ProxyMetrics {
      ds::Array<std::uint64_t, ProxyCounters::capacity> counters{};
      std::uint32_t active_connections = 0;
      std::uint64_t connection_limit_drops = 0;

      [[nodiscard]] std::uint64_t read(ProxyCounter counter) const noexcept;
    };

  }
}
