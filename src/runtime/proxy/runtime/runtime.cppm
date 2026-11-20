module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.proxy.runtime;

import std;
import telar.native.nghttp2;
import telar.sys.process;
import telar.tbc;

import telar.runtime.vocabulary.exchange;
import telar.runtime.exchange_capture.pipeline;
import telar.runtime.exchange_capture.producer;
import telar.runtime.proxy.intercepted_relay;
import telar.runtime.proxy.http2_capture_streams;
import telar.runtime.platform.stream_read_buffer;
import telar.runtime.platform.event_loop;
import telar.runtime.traffic.control_protocol;
import telar.runtime.proxy.relay_direction;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.runtime.http2.direction_observer;
import telar.runtime.http.message;
import telar.runtime.http2.frame_reader;
import telar.runtime.tls.interception;
import telar.runtime.platform.tunnel_sockets;
import telar.runtime.proxy.authenticate;
import telar.platform.net;
import telar.platform.process;
import telar.runtime.redirect.ingress;
import telar.tls;
import telar.platform.primitives;
import telar.wire.vocabulary;
import telar.wire.runtime;
import telar.platform.error;
import telar.platform.events;
import telar.platform.fs;
import telar.platform.paths;
import telar.platform.thread;
import telar.runtime.platform.system_certificates;
import telar.runtime.tls.system_root_bundle;
import telar.sys.posix;
import telar.base.text;
import telar.config.runtime;
import telar.runtime.http.content;
import telar.runtime.http1.head;
import telar.runtime.platform.name_resolutions;
import telar.runtime.platform.signals;
import telar.base.ds;

namespace telar::runtime {

  // The status classes of HTTP the capture and the interception tell apart.
  inline constexpr std::uint16_t first_successful_status = 200;
  inline constexpr std::uint16_t reset_content_status = 205;
  inline constexpr std::uint16_t first_redirection_status = 300;
  inline constexpr std::uint16_t first_error_status = 400;

  // Writes a line on stderr of what befell the proxy's `subject`, for a failure nothing else hears of.
  void reportProxy(std::string_view subject, std::string_view detail, std::string_view more = {}) noexcept;

}

// Interface: proxy/http1_capture_policy.cppm
export {
  namespace telar::runtime {

    template <typename Capture>
    concept Http1CapturePolicy = requires(Capture& capture, CaptureSide side, std::string_view head, std::span<const std::uint8_t> body, std::uint16_t status) {
      { capture.begin() } noexcept -> std::same_as<void>;
      { capture.head(side, head) } noexcept -> std::same_as<void>;
      { capture.payload(side, body) } noexcept -> std::same_as<void>;
      { capture.finishRequest() } noexcept -> std::same_as<void>;
      { capture.finishResponse(status, true) } noexcept -> std::same_as<void>;
      { capture.discardInformational() } noexcept -> std::same_as<void>;
      { capture.fail() } noexcept -> std::same_as<void>;
    };

    struct IgnoreHttp1Capture {
      constexpr void begin() noexcept {}

      constexpr void head(CaptureSide /*side*/, std::string_view /*bytes*/) noexcept {}

      constexpr void payload(CaptureSide /*side*/, std::span<const std::uint8_t> /*bytes*/) noexcept {}

      constexpr void finishRequest() noexcept {}

      constexpr void finishResponse(std::uint16_t /*status*/, bool /*complete*/ = true) noexcept {}

      constexpr void discardInformational() noexcept {}

      constexpr void fail() noexcept {}
    };

    static_assert(Http1CapturePolicy<IgnoreHttp1Capture>);

  }
}

// Interface: proxy/http1_capture.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's clock.
    template <CaptureClock Clock = CaptureWallClock>
    class TBC_GENERIC Http1Capture {
    public:
      inline explicit Http1Capture(ConcurrentMemory& memory, CaptureProducer* producer, CaptureStart context) noexcept
          : producer_(producer),
            context_(std::move(context)),
            exchange_(memory) {}

      inline void begin() noexcept {
        exchange_.request.reset();
        exchange_.response.reset();
        if (producer_ == nullptr) {
          return;
        }

        context_.started_at_ms = Clock::now();
        context_.side = CaptureSide::request;
        exchange_.request = producer_->start(context_);
        context_.side = CaptureSide::response;
        exchange_.response = producer_->start(context_);
      }

      inline void head(CaptureSide side, std::string_view bytes) noexcept {
        if (auto& half = select(side)) {
          half.getMut().appendHead(bytes);
        }
      }

      inline void payload(CaptureSide side, std::span<const std::uint8_t> bytes) noexcept {
        if (auto& half = select(side)) {
          half.getMut().append(half->bodyPart(), bytes);
        }
      }

      inline void finishRequest() noexcept {
        finish(CaptureSide::request, CaptureOutcome::finished);
      }

      inline void finishResponse(std::uint16_t status, bool complete = true) noexcept {
        if (exchange_.response) {
          exchange_.response.getMut().status_code = status;
        }

        finish(CaptureSide::response, !complete || status >= first_error_status ? CaptureOutcome::failed : CaptureOutcome::finished);
      }

      inline void discardInformational() noexcept {
        if (exchange_.response) {
          exchange_.response.getMut().head.reset();
        }
      }

      inline void fail() noexcept {
        finish(CaptureSide::request, CaptureOutcome::failed);
        finish(CaptureSide::response, CaptureOutcome::failed);
      }

    private:
      using Half = CaptureProducer::Half;

      inline Half& select(CaptureSide side) noexcept {
        return side == CaptureSide::request ? exchange_.request : exchange_.response;
      }

      inline void finish(CaptureSide side, CaptureOutcome outcome) noexcept {
        auto& half = select(side);
        if (half) {
          half.getMut().finish(outcome, Clock::now());
          producer_->publish(std::move(half));
        }
      }

      CaptureProducer* producer_;
      CaptureStart context_;
      CapturedExchange exchange_;
    };

  }
}

// Interface: proxy/http1_observer.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's capture policy, and called for every read the relay makes.
    template <Http1CapturePolicy Capture>
    class TBC_GENERIC Http1TransportObserver {
    public:
      inline explicit Http1TransportObserver(ProxyCounters& counters, Capture& capture, CaptureSide side) noexcept
          : counters_(counters),
            capture_(capture),
            side_(side) {}

      inline void headStarted() noexcept {}

      inline void head(std::string_view bytes) noexcept {
        capture_.head(side_, bytes);
      }

      inline void payload(std::span<const std::uint8_t> bytes) noexcept {
        capture_.payload(side_, bytes);
      }

      inline void lineTooLong(Http1Line line) noexcept {
        counters_.record(line == Http1Line::chunk_size ? ProxyCounter::http1_chunk_line_too_long : ProxyCounter::http1_trailer_line_too_long);
      }

    private:
      ProxyCounters& counters_;
      Capture& capture_;
      CaptureSide side_;
    };

    template <Http1CapturePolicy Capture>
    Http1TransportObserver(ProxyCounters& counters, Capture& capture, CaptureSide side) -> Http1TransportObserver<Capture>;

    static_assert(Http1Observer<Http1TransportObserver<IgnoreHttp1Capture>>);

  }
}

// Interface: proxy/socket_interest.cppm
export {
  namespace telar::runtime {

    struct SocketInterest {
      bool readable = false;
      bool writable = false;
      bool completion = false;

      void include(StreamReadiness readiness) noexcept;

      auto operator==(const SocketInterest&) const noexcept -> bool = default;

      [[nodiscard]] auto satisfies(StreamReadiness readiness) const noexcept -> bool;
    };

    struct TunnelReadiness {
      SocketInterest child;
      SocketInterest origin;

      static constexpr auto available() noexcept -> TunnelReadiness {
        return {
            .child = {
                .readable = true,
                .writable = true,
                .completion = true,
            },
            .origin = {
                .readable = true,
                .writable = true,
                .completion = true,
            },
        };
      }
    };

  }
}

// Interface: proxy/http1_connection.cppm
export {
  namespace telar::runtime {

    // An HTTP/1 exchange on a connection; without an HttpControl in its context, its relays forward
    // each message as it comes.
    // Generic over the caller's capture policy, and called for every read the relay makes.
    template <Http1CapturePolicy Capture = IgnoreHttp1Capture>
    class TBC_GENERIC Http1Connection {
      using Relay = Http1InterceptedRelay;

    public:
      inline Http1Connection(ConcurrentMemory& memory, ProxyCounters& counters, Capture capture = {}, HttpRelayContext context = {})
          : counters_(counters),
            capture_(std::move(capture)),
            request_(memory, context, false),
            response_(memory, std::move(context), true) {
        capture_.begin();
      }

      template <PeekableByteStream Child, PeekableByteStream Origin>
      inline bool advance(Child& child, Origin& origin, TunnelReadiness readiness) noexcept {
        TELAR_TRACE("proxy.http1Exchange");
        if (!rejection_.empty()) {
          return sendRejection(child);
        }

        bool active = false;

        for (std::size_t round = 0; round < maximum_rounds && !finished_ && !upgraded_; ++round) {
          const auto request = requestTurn(child, origin, readiness);

          active = active || request.active;
          if (request.round == Round::rejected) {
            return sendRejection(child) || active;
          }

          if (request.round == Round::stopped) {
            break;
          }

          const auto response = responseTurn(child, origin, readiness);

          active = active || response.active;
          if (response.round == Round::rejected) {
            return sendRejection(child) || active;
          }

          if (response.round == Round::stopped || (response.round == Round::going && !request.progress && !response.progress)) {
            break;
          }
        }

        return active;
      }

      [[nodiscard]] inline SocketInterest childInterest() const noexcept {
        if (!rejection_.empty()) {
          SocketInterest interest;

          interest.include(rejection_waiting_);
          return interest;
        }

        SocketInterest interest;

        interest.include(request_.sourceInterest());
        if (!request_.continueReply().remaining().empty()) {
          interest.include(continue_waiting_);
        }

        if (response_started_) {
          interest.include(response_.destinationInterest());
        }

        return interest;
      }

      [[nodiscard]] inline SocketInterest originInterest() const noexcept {
        SocketInterest interest;

        if (rejection_.empty()) {
          interest.include(request_.destinationInterest());
          if (response_started_) {
            interest.include(response_.sourceInterest());
          }
        }

        return interest;
      }

      [[nodiscard]] inline bool readsChild() const noexcept {
        return rejection_.empty() && request_.sourceInterest() != StreamReadiness::none;
      }

      [[nodiscard]] inline bool readsOrigin() const noexcept {
        return rejection_.empty() && response_started_ && response_.sourceInterest() != StreamReadiness::none;
      }

      [[nodiscard]] inline bool finished() const noexcept {
        return finished_;
      }

      [[nodiscard]] inline bool upgraded() const noexcept {
        return upgraded_;
      }

      [[nodiscard]] inline bool idle() const noexcept {
        return !finished_ && !upgraded_ && !request_.started();
      }

      [[nodiscard]] inline std::uint32_t inflight() const noexcept {
        return !finished_ && !upgraded_ && request_.started() ? 1 : 0;
      }

      [[nodiscard]] inline auto deadline() const noexcept -> ds::Option<std::chrono::steady_clock::time_point> {
        return earliest(request_.deadline(), response_.deadline());
      }

    private:
      using State = Http1MessageRelay::State;

      // How a round of the exchange left off after one of its messages: going on, done with the
      // message so the next round starts (`finished`), stopped for now, or rejecting the head.
      enum class Round : std::uint8_t {
        going,
        finished,
        stopped,
        rejected,
      };

      // What one message did in a round: whether it moved, and whether the round was active at all,
      // which an interim 100 Continue makes it.
      struct Turn {
        Round round = Round::going;
        bool progress = false;
        bool active = false;
      };

      template <PeekableByteStream Child, PeekableByteStream Origin>
      inline Turn requestTurn(Child& child, Origin& origin, TunnelReadiness readiness) noexcept {
        Turn turn{.progress = advanceMessage(request_, Observer{counters_, capture_, CaptureSide::request}, child, origin, readiness)};

        turn.active = turn.progress;
        if (sendContinue(child)) {
          turn.active = true;
          turn.progress = advanceMessage(request_, Observer{counters_, capture_, CaptureSide::request}, child, origin, TunnelReadiness::available()) || turn.progress;
        }

        if (request_.state() == State::head_too_large) {
          rejectHead(true);
          turn.round = Round::rejected;
          return turn;
        }

        if (request_.state() == State::failed) {
          if (request_.head()) {
            capture_.fail();
          }

          finished_ = true;
          turn.round = Round::stopped;
          return turn;
        }

        if (request_.state() == State::complete) {
          capture_.finishRequest();
        }

        if (!response_started_ && request_.head()) {
          response_.reset(true, request_.head()->head_request);
          response_.destinationHead(request_.originalHead());
          response_started_ = true;
        }

        if (!response_started_) {
          turn.round = Round::stopped;
        }

        return turn;
      }

      template <PeekableByteStream Child, PeekableByteStream Origin>
      inline Turn responseTurn(Child& child, Origin& origin, TunnelReadiness readiness) noexcept {
        Turn turn{.progress = advanceMessage(response_, Observer{counters_, capture_, CaptureSide::response}, origin, child, {readiness.origin, readiness.child})};

        turn.active = turn.progress;
        if (response_.state() == State::head_too_large) {
          capture_.fail();
          rejectHead(false);
          turn.round = Round::rejected;
        } else if (response_.state() == State::failed) {
          capture_.fail();
          finished_ = true;
          turn.round = Round::stopped;
        } else if (response_.state() == State::complete) {
          finishResponse();
          turn.round = Round::finished;
        }

        return turn;
      }

      using Observer = Http1TransportObserver<Capture>;

      template <PeekableByteStream Source, ByteStream Destination>
      inline static bool advanceMessage(Relay& message, Observer observer, Source& source, Destination& destination, TunnelReadiness readiness) noexcept {
        const auto deadline = message.deadline();
        const bool expired = deadline && std::chrono::steady_clock::now() >= *deadline;
        if (!expired && !readiness.child.satisfies(message.sourceInterest()) && !readiness.origin.satisfies(message.destinationInterest())) {
          return false;
        }

        return message.advance(source, destination, observer);
      }

      template <ByteStream Child>
      inline bool sendContinue(Child& child) noexcept {
        if (request_.state() == State::failed) {
          return false;
        }

        auto& reply = request_.continueReplyMut();
        if (reply.remaining().empty()) {
          return false;
        }

        const auto result = reply.write(child);
        if (result.state == StreamResult::State::blocked) {
          continue_waiting_ = result.waiting;
          return false;
        }

        if (result.state != StreamResult::State::data || result.bytes == 0) {
          finished_ = true;
          return false;
        }

        continue_waiting_ = StreamReadiness::writable;
        return true;
      }

      inline void finishResponse() noexcept {
        const auto& head = *response_.head();
        if (head.informational) {
          capture_.discardInformational();
          response_.reset(true, request_.head()->head_request);
          return;
        }

        capture_.finishResponse(head.status, !response_.captureIncomplete());
        if (request_.state() == State::complete && head.upgrade) {
          upgraded_ = true;
        } else if (request_.state() != State::complete || head.closes) {
          finished_ = true;
        } else {
          request_.reset(false);
          response_started_ = false;
          capture_.begin();
        }
      }

      // Answers a head too large to relay with the fixed response of its side.
      inline void rejectHead(bool request) noexcept {
        counters_.record(ProxyCounter::http1_head_too_large);
        rejection_ = StaticReply{request ? proxy_responses::head_too_large : proxy_responses::bad_gateway_closing};
      }

      template <ByteStream Child>
      inline bool sendRejection(Child& child) noexcept {
        const auto sent = rejection_.write(child);
        if (sent.state == StreamResult::State::blocked) {
          rejection_waiting_ = sent.waiting;
          return false;
        }

        if (sent.state != StreamResult::State::data || sent.bytes == 0) {
          finished_ = true;
          return false;
        }

        finished_ = rejection_.sent();
        return true;
      }

      static constexpr std::size_t maximum_rounds = 8;
      ProxyCounters& counters_;
      [[no_unique_address]] Capture capture_;
      Relay request_;
      Relay response_;
      StreamReadiness continue_waiting_ = StreamReadiness::writable;
      StaticReply rejection_;
      StreamReadiness rejection_waiting_ = StreamReadiness::writable;
      bool response_started_ = false;
      bool finished_ = false;
      bool upgraded_ = false;
    };

  }
}

// Interface: proxy/socket_watch.cppm
export {
  namespace telar::runtime {

    class SocketWatch {
    public:
      // Generic over the caller's event loop.
      template <EventLoop Poller>
      TBC_GENERIC void update(Poller& poller, int descriptor, std::uint64_t token, SocketInterest interest) {
        const bool changed = descriptor != descriptor_ || token != token_ || interest != interest_;

        if (descriptor != descriptor_) {
          remove(poller);
          descriptor_ = descriptor;
        }

        token_ = token;
        if (changed && descriptor_ >= 0) {
          poller.readInterest(descriptor_, token_, interest.readable);
          poller.writeInterest(descriptor_, token_, interest.writable);
        }

        interest_ = interest;
      }

      template <EventLoop Poller>
      TBC_GENERIC void remove(Poller& poller) noexcept {
        if (descriptor_ >= 0) {
          poller.remove(descriptor_);
          descriptor_ = -1;
        }

        interest_ = {};
      }

      [[nodiscard]] bool matches(const Event& event) const noexcept;

    private:
      int descriptor_ = -1;
      std::uint64_t token_ = 0;
      SocketInterest interest_;
    };

  }
}

// Interface: proxy/connection_observation.cppm
export {
  namespace telar::runtime {

    struct ConnectionObservation {
      ProxyCounters& counters;
      CaptureProducer* captures;
      std::uint64_t identity;
      traffic::FlowControl* flows = nullptr;
    };

  }
}

// Interface: proxy/duplex_relay.cppm
export {
  namespace telar::runtime {

    // The tunnel's loop for every read, generic over the caller's streams and buffer size.
    template <std::size_t BufferCapacity = RelayDirection<>::capacity>
    class TBC_GENERIC DuplexRelay {
      using Direction = RelayDirection<BufferCapacity>;

    public:
      template <ByteStream Child, ByteStream Origin>
      inline bool advance(Child& child, Origin& origin, TunnelReadiness readiness) noexcept {
        const bool outgoing = transfer(outbound_, child, origin, readiness.child, readiness.origin);
        const bool incoming = transfer(inbound_, origin, child, readiness.origin, readiness.child);

        return outgoing || incoming;
      }

      [[nodiscard]] inline bool finished() const noexcept {
        return outbound_.finished() && inbound_.finished();
      }

      [[nodiscard]] inline bool halfClosed() const noexcept {
        return outbound_.finished() || inbound_.finished();
      }

      [[nodiscard]] inline bool readsChild() const noexcept {
        return outbound_.wantsRead();
      }

      [[nodiscard]] inline bool readsOrigin() const noexcept {
        return inbound_.wantsRead();
      }

      [[nodiscard]] inline SocketInterest childInterest() const noexcept {
        SocketInterest interest;

        interest.include(outbound_.sourceInterest());
        interest.include(inbound_.destinationInterest());
        return interest;
      }

      [[nodiscard]] inline SocketInterest originInterest() const noexcept {
        SocketInterest interest;

        interest.include(inbound_.sourceInterest());
        interest.include(outbound_.destinationInterest());
        return interest;
      }

    private:
      template <ByteStream Source, ByteStream Destination>
      inline static bool transfer(Direction& direction, Source& source, Destination& destination, SocketInterest source_ready, SocketInterest destination_ready) noexcept {
        if (!source_ready.satisfies(direction.sourceInterest()) && !destination_ready.satisfies(direction.destinationInterest())) {
          return false;
        }

        bool active = false;

        for (std::size_t round = 0; round < maximum_rounds; ++round) {
          const auto progress = direction.advance(source, destination);

          active = active || progress.active();
          if (direction.wantsWrite() || progress.read < Direction::capacity) {
            break;
          }
        }

        return active;
      }

      static constexpr std::size_t maximum_transfer_bytes = std::size_t{128} * 1024;
      static_assert(BufferCapacity <= maximum_transfer_bytes);
      static constexpr std::size_t maximum_rounds = maximum_transfer_bytes / BufferCapacity;
      Direction outbound_;
      Direction inbound_;
    };

  }
}

// Interface: proxy/flow_state.cppm
export {
  namespace telar::runtime {

    // One direction of a flow: the chunk a hook was offered and the replacement it chose. Its flow owns the
    // identity every event carries and the control it reports to.
    class FlowGate {
    public:
      [[nodiscard]] bool rejected() const noexcept;

      [[nodiscard]] tbc::val_static<std::string_view> failureReason() const noexcept;

    private:
      friend class FlowState;

      SensitiveBuffer<traffic::FlowControl::chunk_bytes> replacement_;
      std::uint64_t ticket_ = 0;
      std::uint64_t offset_ = 0;
      std::size_t original_size_ = 0;
      std::size_t replacement_size_ = 0;
      std::size_t sent_ = 0;
      bool offered_ = false;
      bool replacing_ = false;
      bool rejected_ = false;
      tbc::val_static<std::string_view> failure_;
    };

    class FlowState;

    // A stream of one direction of a flow, whose writes a hook may hold or replace.
    // Generic over the caller's stream, and called for every read the relay makes.
    template <ByteStream Stream>
    class TBC_GENERIC FlowStream {
    public:
      inline explicit FlowStream(Stream& stream, FlowState* flow, traffic::Direction direction) noexcept
          : stream_(stream),
            flow_(flow),
            direction_(direction) {}

      inline StreamResult read(std::span<Byte> bytes) noexcept;
      inline StreamResult write(std::span<const Byte> bytes) noexcept;

      inline void halfClose() noexcept {
        stream_.halfClose();
      }

      inline StreamResult peek(std::span<Byte> bytes) noexcept
        requires PeekableByteStream<Stream>;
      inline StreamView peekView(std::size_t maximum) noexcept
        requires BufferedByteStream<Stream>;

      inline void consume(std::size_t bytes) noexcept
        requires BufferedByteStream<Stream>
      {
        stream_.consume(bytes);
      }

    private:
      Stream& stream_;
      FlowState* flow_;
      traffic::Direction direction_;
    };

    // A proxied flow as hooks see it. It owns the identity its events carry, so an event it hands out views
    // the flow and nothing that outlives a call is kept elsewhere.
    class FlowState {
    public:
      FlowState() = default;
      FlowState(const FlowState&) = delete;
      FlowState& operator=(const FlowState&) = delete;
      FlowState(FlowState&&) = delete;
      FlowState& operator=(FlowState&&) = delete;

      ~FlowState();

      // The control the flow reports to is region `a`; the reasons it gives are literals.
      void open(tbc::val_a<traffic::FlowControl*> control, std::uint64_t id, TunnelSockets sockets, std::string_view host) noexcept;

      void visibility(traffic::Visibility value) noexcept;

      void reason(tbc::val_static<std::string_view> value) noexcept;

      // The flow's identity, which views the flow.
      [[nodiscard]] traffic::FlowEvent context() const noexcept;

      void error(tbc::val_static<std::string_view> value) noexcept;

      [[nodiscard]] bool rejected() const noexcept;

      [[nodiscard]] ds::Option<traffic::FlowControl::Time> deadline() const noexcept;

      // A direction fails once; the reason is reported as the opposite direction's when it was reading.
      void fail(traffic::Direction direction, tbc::val_static<std::string_view> reason, bool reading = false) noexcept;

      // The caller retains its input until the entire replacement has been sent, including partial TLS writes.
      template <ByteStream Stream>
      TBC_GENERIC StreamResult write(traffic::Direction direction, Stream& stream, std::span<const Byte> bytes) noexcept {
        auto& gate = this->gate(direction);
        if (gate.rejected_) {
          return {.state = StreamResult::State::failed};
        }

        if (!control_) {
          return stream.write(bytes);
        }

        if (!gate.offered_) {
          auto offered = event(direction);

          offered.offset = gate.offset_;
          offered.bytes = bytes.first(std::min(bytes.size(), traffic::FlowControl::chunk_bytes));
          gate.original_size_ = offered.bytes.size();
          gate.ticket_ = control_->intercept(offered);
          gate.offered_ = true;
        }

        if (gate.ticket_) {
          const auto decision = control_->poll(gate.ticket_, gate.replacement_.bytes());
          if (decision.verdict == traffic::Verdict::pending) {
            return {.state = StreamResult::State::blocked, .bytes = 0, .waiting = StreamReadiness::completion};
          }

          gate.ticket_ = 0;
          if (decision.verdict == traffic::Verdict::reject) {
            fail(direction, "hook_rejected");
            return {.state = StreamResult::State::failed};
          }

          gate.replacing_ = decision.verdict == traffic::Verdict::replace;
          gate.replacement_size_ = decision.bytes;
        }

        const auto input = bytes.first(gate.original_size_);
        const auto output = gate.replacing_ ? gate.replacement_.bytes().first(gate.replacement_size_).subspan(gate.sent_) : input;
        if (output.empty()) {
          return complete(gate);
        }

        const auto result = stream.write(output);
        if (result.state != StreamResult::State::data) {
          if (result.state == StreamResult::State::failed || result.state == StreamResult::State::ended) {
            fail(direction, "socket_write_failed");
          }

          return result;
        }

        auto written = event(direction);

        written.offset = gate.offset_;
        written.bytes = output.first(result.bytes);
        control_->observeFlow(traffic::Kind::stream_data, written);
        gate.offset_ += result.bytes;
        if (gate.replacing_) {
          gate.sent_ += result.bytes;
          return gate.sent_ == gate.replacement_size_ ? complete(gate) : StreamResult{.state = StreamResult::State::blocked, .bytes = 0, .waiting = StreamReadiness::writable};
        }

        gate.offered_ = false;
        return result;
      }

    private:
      static traffic::Direction opposite(traffic::Direction direction) noexcept;

      FlowGate& gate(traffic::Direction direction) noexcept;

      [[nodiscard]] traffic::FlowEvent event(traffic::Direction direction) const noexcept;

      static StreamResult complete(FlowGate& gate) noexcept;

      static void endpoint(int socket, FixedText<traffic::FlowIdentity::endpoint_bytes>& result) noexcept;

      tbc::val_a<traffic::FlowControl*> control_ = nullptr;
      traffic::FlowIdentity identity_;
      tbc::val_static<std::string_view> reason_ = "closed";
      tbc::val_a<FlowGate> outbound_;
      tbc::val_a<FlowGate> inbound_;
    };

    template <ByteStream Stream>
    inline StreamResult FlowStream<Stream>::read(std::span<Byte> bytes) noexcept {
      const auto result = stream_.read(bytes);
      if (flow_ && result.state == StreamResult::State::failed) {
        flow_->fail(direction_, "socket_read_failed", true);
      }

      return result;
    }

    template <ByteStream Stream>
    inline StreamResult FlowStream<Stream>::write(std::span<const Byte> bytes) noexcept {
      return (flow_ != nullptr) ? flow_->write(direction_, stream_, bytes) : stream_.write(bytes);
    }

    template <ByteStream Stream>
    inline StreamResult FlowStream<Stream>::peek(std::span<Byte> bytes) noexcept
      requires PeekableByteStream<Stream>
    {
      const auto result = stream_.peek(bytes);
      if (flow_ && result.state == StreamResult::State::failed) {
        flow_->fail(direction_, "socket_read_failed", true);
      }

      return result;
    }

    template <ByteStream Stream>
    inline StreamView FlowStream<Stream>::peekView(std::size_t maximum) noexcept
      requires BufferedByteStream<Stream>
    {
      const auto result = stream_.peekView(maximum);
      if (flow_ && result.state == StreamResult::State::failed) {
        flow_->fail(direction_, "socket_read_failed", true);
      }

      return result;
    }

  }
}

// Interface: proxy/http2_capture.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's clock.
    template <CaptureClock Clock = CaptureWallClock>
    class TBC_GENERIC Http2Capture {
    public:
      inline explicit Http2Capture(CaptureProducer* producer, ProxyCounters& counters, CaptureStart context) noexcept
          : request_(producer, counters, context, CaptureSide::request),
            response_(producer, counters, context, CaptureSide::response) {}

      inline void observe(Http2Direction direction, const Http2Event& event) noexcept {
        auto& streams = select(direction);

        switch (event.kind) {
        case Http2Event::Kind::request_header:
        case Http2Event::Kind::response_header:
          streams.head(event);
          break;
        case Http2Event::Kind::request_body:
        case Http2Event::Kind::response_body:
          streams.body(event);
          break;
        case Http2Event::Kind::request_finished:
          streams.finish(event.stream, CaptureOutcome::finished);
          break;
        case Http2Event::Kind::response_ended:
          streams.finish(event.stream, event.status >= first_error_status ? CaptureOutcome::failed : CaptureOutcome::finished);
          break;
        case Http2Event::Kind::stream_reset:
        case Http2Event::Kind::connection_lost:
          streams.finish(event.stream, CaptureOutcome::failed);
          break;
        case Http2Event::Kind::request_started:
        case Http2Event::Kind::response_activity:
          break;
        }
      }

      inline void finish(Http2Direction direction) noexcept {
        select(direction).finish();
      }

    private:
      inline Http2CaptureStreams<Clock>& select(Http2Direction direction) noexcept {
        return direction == Http2Direction::request ? request_ : response_;
      }

      Http2CaptureStreams<Clock> request_;
      Http2CaptureStreams<Clock> response_;
    };

  }
}

// Interface: proxy/http2_connection.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's capture policy, and called for every read the relay makes.
    template <Allocator Memory, Http2CapturePolicy Capture = IgnoreHttp2Capture>
    class TBC_GENERIC Http2Connection {
    public:
      inline explicit Http2Connection(Memory& memory, ProxyCounters& counters, Capture capture = {}) noexcept
          : counters_(counters),
            capture_(std::move(capture)),
            request_(memory, Http2Direction::request),
            response_(memory, Http2Direction::response) {}

      inline ~Http2Connection() {
        settle();
      }

      Http2Connection(const Http2Connection&) = delete;
      Http2Connection& operator=(const Http2Connection&) = delete;
      Http2Connection(Http2Connection&&) = delete;
      Http2Connection& operator=(Http2Connection&&) = delete;

      template <ByteStream Child, ByteStream Origin>
      inline bool advance(Child& child, Origin& origin, TunnelReadiness readiness) noexcept {
        TELAR_TRACE("proxy.http2Exchange");
        if (finished()) {
          return false;
        }

        const bool outgoing = transfer(request_, DirectionSink{streams_, capture_, request_.kind}, child, origin, readiness);
        const bool incoming = transfer(response_, DirectionSink{streams_, capture_, response_.kind}, origin, child, {readiness.origin, readiness.child});

        if (finished()) {
          origin.halfClose();
          settle();
        }

        return outgoing || incoming;
      }

      [[nodiscard]] inline bool finished() const noexcept {
        return response_.relay.finished();
      }

      [[nodiscard]] inline bool halfClosed() const noexcept {
        return request_.relay.finished() || response_.relay.finished();
      }

      [[nodiscard]] inline bool readsChild() const noexcept {
        return !finished() && request_.relay.wantsRead();
      }

      [[nodiscard]] inline bool readsOrigin() const noexcept {
        return response_.relay.wantsRead();
      }

      [[nodiscard]] inline std::uint32_t inflight() const noexcept {
        return streams_.size();
      }

      [[nodiscard]] inline SocketInterest childInterest() const noexcept {
        SocketInterest interest;

        interest.include(request_.relay.sourceInterest());
        interest.include(response_.relay.destinationInterest());
        return interest;
      }

      [[nodiscard]] inline SocketInterest originInterest() const noexcept {
        SocketInterest interest;

        interest.include(response_.relay.sourceInterest());
        interest.include(request_.relay.destinationInterest());
        return interest;
      }

    private:
      using Streams = Http2StreamIds<2 * Http2StreamTracker::capacity>;

      inline void observe(Http2Direction direction, const Http2Event& event) noexcept {
        observe(streams_, capture_, direction, event);
      }

      inline static void observe(Streams& streams, Capture& capture, Http2Direction direction, const Http2Event& event) noexcept {
        if (event.kind == Http2Event::Kind::request_started) {
          streams.start(event.stream);
        } else if (event.kind == Http2Event::Kind::response_ended || event.kind == Http2Event::Kind::stream_reset) {
          streams.finish(event.stream);
        }

        capture.observe(direction, event);
      }

      // Where a direction's events go: the tracked streams and the capture, lent while it transfers.
      struct DirectionSink {
        Streams& streams;
        Capture& capture;
        Http2Direction direction;

        inline void emit(const Http2Event& event) noexcept {
          observe(streams, capture, direction, event);
        }
      };

      struct Direction {
        inline explicit Direction(Memory& memory, Http2Direction value) noexcept
            : observer(memory, value),
              kind(value) {}

        Http2DirectionObserver<Memory> observer;
        Http2Direction kind;
        RelayDirection<> relay;
      };

      template <ByteStream Source, ByteStream Destination>
      inline static bool transfer(Direction& direction, DirectionSink sink, Source& source, Destination& destination, TunnelReadiness readiness) noexcept {
        if (!readiness.child.satisfies(direction.relay.sourceInterest()) && !readiness.origin.satisfies(direction.relay.destinationInterest())) {
          return false;
        }

        bool active = false;

        for (std::size_t round = 0; round < maximum_rounds; ++round) {
          const auto progress = direction.relay.advance(source, destination, [&](RelayDirection<>::Observation stage, std::span<const std::uint8_t> bytes) noexcept {
            const bool request = direction.kind == Http2Direction::request;
            if ((request && stage == RelayDirection<>::Observation::received) || (!request && stage == RelayDirection<>::Observation::forwarded)) {
              direction.observer.observe(bytes, sink);
            }
          });

          active = active || progress.active();
          if (direction.relay.wantsWrite() || progress.read < RelayDirection<>::capacity) {
            break;
          }
        }

        if (direction.relay.finished()) {
          sink.capture.finish(direction.kind);
        }

        return active;
      }

      inline void settle() noexcept {
        if (settled_) {
          return;
        }

        settled_ = true;
        record(request_.observer.finish());
        record(response_.observer.finish());
        capture_.finish(Http2Direction::request);
        capture_.finish(Http2Direction::response);
      }

      inline void record(const Http2Observer<Memory>::Statistics& statistics) noexcept {
        if (statistics.decode_failed) {
          counters_.record(ProxyCounter::h2_decode_failure);
        }

        if (statistics.header_block_too_large) {
          counters_.record(ProxyCounter::h2_header_block_too_large);
        }

        counters_.record(ProxyCounter::h2_stream_untracked, statistics.untracked_streams);
      }

      static constexpr std::size_t maximum_rounds = 8;
      ProxyCounters& counters_;
      [[no_unique_address]] Capture capture_;
      Streams streams_;
      Direction request_;
      Direction response_;
      bool settled_ = false;
    };

  }
}

// Interface: proxy/http2_endpoint_connection.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's capture policy, and called for every read the relay makes.
    template <ConcurrentAllocator Memory, Http2CapturePolicy Capture = IgnoreHttp2Capture>
    class TBC_GENERIC Http2EndpointConnection {
      static constexpr std::size_t maximum_streams = 64;
      static constexpr std::size_t connection_bytes = std::size_t{16} * 1024 * 1024;
      static constexpr std::size_t io_bytes = std::size_t{16} * 1024;
      static constexpr std::size_t wire_body_bytes = HttpMessageLimits::body_bytes + HttpMessageLimits::head_bytes;
      using Local = SynchronizedAllocator<BudgetAllocator<Memory>>;
      using Secure = ErasingAllocator<Local>;
      using Time = traffic::FlowControl::Time;
      struct Stream;
      struct Endpoint;

      struct Half {
        inline Half(Local& memory, Stream& holder, bool response)
            : secure(memory),
              message(memory, response),
              queue(secure, wire_body_bytes),
              stream(holder) {
          message.version = HttpVersion::http2;
        }

        // The queue keeps the allocator beside it, so a half stays inside its stream.
        Half(const Half&) = delete;
        Half& operator=(const Half&) = delete;
        Half(Half&&) = delete;
        Half& operator=(Half&&) = delete;
        ~Half() = default;
        Secure secure;
        HttpMessage<Local> message;
        ByteQueue<Secure> queue;
        Stream& stream;
        HttpInterceptionSlot<Local> interception;
        std::size_t header_bytes = 0, uncredited = 0;
        bool headers_complete = false, trailer_block = false, ended = false, forwarded = false, streaming = false, discard_body = false;
        unsigned informational = 0;
      };

      struct Stream {
        inline Stream(Local& memory, std::int32_t id)
            : child_id(id),
              request(memory, *this, false),
              response(memory, *this, true) {
          request.message.stream = response.message.stream = static_cast<std::uint32_t>(id);
        }

        Stream(const Stream&) = delete;
        Stream& operator=(const Stream&) = delete;
        Stream(Stream&&) = delete;
        Stream& operator=(Stream&&) = delete;
        ~Stream() = default;

        std::int32_t child_id, origin_id = 0;
        // Each half names the stream that holds it, which stays where nghttp2 was told it is.
        tbc::val_self<Half> request, response;
        bool child_closed = false, origin_closed = false, rejected = false, original_head = false, origin_canceled_for_head = false;
      };

      struct Endpoint {
        inline Endpoint(Local& local, Http2EndpointConnection* connection, bool child_side) // NOLINT(cppcoreguidelines-pro-type-member-init): the input is written by each read before it is parsed
            : memory(local),
              owner(connection),
              child(child_side) {
          nghttp2_session_callbacks* raw_callbacks = nullptr;
          if (nghttp2_session_callbacks_new(&raw_callbacks) != 0) {
            throw std::bad_alloc{};
          }

          const auto callbacks = std::unique_ptr<nghttp2_session_callbacks, decltype(&nghttp2_session_callbacks_del)>{raw_callbacks, &nghttp2_session_callbacks_del};

          nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks.get(), &beginHeaders);
          nghttp2_session_callbacks_set_on_header_callback(callbacks.get(), &header);
          nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks.get(), &data);
          nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks.get(), &frame);
          nghttp2_session_callbacks_set_on_stream_close_callback(callbacks.get(), &closed);
          nghttp2_session_callbacks_set_on_frame_not_send_callback(callbacks.get(), &notSent);
          nghttp2_option* raw_options = nullptr;
          if (nghttp2_option_new(&raw_options) != 0) {
            throw std::bad_alloc{};
          }

          const auto options = std::unique_ptr<nghttp2_option, decltype(&nghttp2_option_del)>{raw_options, &nghttp2_option_del};

          nghttp2_option_set_no_auto_window_update(options.get(), 1);
          nghttp2_option_set_max_outbound_ack(options.get(), maximum_streams);
          const auto result = child ? nghttp2_session_server_new3(&session, callbacks.get(), this, options.get(), this->memory.callbacks()) : nghttp2_session_client_new3(&session, callbacks.get(), this, options.get(), this->memory.callbacks());
          if (result != 0) {
            throw std::bad_alloc{};
          }

          const ds::Array<nghttp2_settings_entry, 4> settings{{{.settings_id = NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = maximum_streams}, {.settings_id = NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = wire_body_bytes}, {.settings_id = NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = HttpMessageLimits::head_bytes}, {.settings_id = NGHTTP2_SETTINGS_ENABLE_PUSH, .value = 0}}};
          if (nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE, settings.data(), child ? settings.size() - 1 : settings.size()) != 0) {
            close();
            throw std::bad_alloc{};
          }
        }

        inline ~Endpoint() {
          close();
        }

        Endpoint(const Endpoint&) = delete;
        Endpoint& operator=(const Endpoint&) = delete;
        Endpoint(Endpoint&&) = delete;
        Endpoint& operator=(Endpoint&&) = delete;

        inline void close() noexcept {
          if (session != nullptr) {
            nghttp2_session_del(session);
            session = nullptr;
          }
        }

        // nghttp2 holds each stream by address and hands it back raw, as its callbacks re-enter the connection.
        [[nodiscard]] inline auto stream(std::int32_t id) const noexcept -> tbc::val_static<Stream*> {
          return tbc::raw(static_cast<Stream*>(nghttp2_session_get_stream_user_data(session, id)));
        }

        inline static int beginHeaders(nghttp2_session* /*session*/, const nghttp2_frame* frame, void* context) noexcept {
          auto& endpoint = *static_cast<Endpoint*>(context);

          try {
            return endpoint.owner->beginHeaders(endpoint.child, *frame);
          } catch (...) {
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
          }
        }

        // These signatures are fixed by nghttp2's C callback ABI.
        inline static int header(nghttp2_session* /*session*/, const nghttp2_frame* frame, const std::uint8_t* name, std::size_t name_size, const std::uint8_t* value, std::size_t value_size, std::uint8_t /*flags*/, void* context) noexcept { // NOLINT(readability-function-size): nghttp2's header callback takes eight parameters
          auto& endpoint = *static_cast<Endpoint*>(context);
          auto* stream = endpoint.stream(frame->hd.stream_id);
          if ((stream == nullptr) || stream->rejected) {
            return 0;
          }

          try {
            endpoint.owner->header(endpoint.child, *stream, {reinterpret_cast<const char*>(name), name_size}, {reinterpret_cast<const char*>(value), value_size}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): nghttp2 hands a field as bytes, which char may alias
            return 0;
          } catch (...) {
            endpoint.owner->reject(*stream, "http2_invalid_headers");
            return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
          }
        }

        inline static int data(nghttp2_session* /*session*/, std::uint8_t flags, std::int32_t id, const std::uint8_t* data, std::size_t size, void* context) noexcept { // NOLINT(readability-function-size,bugprone-easily-swappable-parameters): nghttp2's data callback fixes these six parameters
          auto& endpoint = *static_cast<Endpoint*>(context);
          if (nghttp2_session_consume_connection(endpoint.session, size) != 0) {
            return NGHTTP2_ERR_CALLBACK_FAILURE;
          }

          auto* stream = endpoint.stream(id);
          if ((stream == nullptr) || stream->rejected) {
            return 0;
          }

          try {
            endpoint.owner->data(endpoint.child, *stream, {data, size}, (flags & NGHTTP2_FLAG_END_STREAM) != 0);
          } catch (...) {
            endpoint.owner->reject(*stream, "http2_buffer_limit");
          }

          return 0;
        }

        inline static int frame(nghttp2_session* /*session*/, const nghttp2_frame* frame, void* context) noexcept {
          auto& endpoint = *static_cast<Endpoint*>(context);

          try {
            endpoint.owner->frame(endpoint.child, *frame);
            return 0;
          } catch (...) {
            if (auto* stream = endpoint.stream(frame->hd.stream_id)) {
              endpoint.owner->reject(*stream, "http2_message_failed");
              return 0;
            }

            return NGHTTP2_ERR_CALLBACK_FAILURE;
          }
        }

        inline static int closed(nghttp2_session* /*session*/, std::int32_t id, std::uint32_t error, void* context) noexcept { // NOLINT(bugprone-easily-swappable-parameters): nghttp2's stream close callback fixes these parameters
          auto& endpoint = *static_cast<Endpoint*>(context);
          if (auto* stream = endpoint.stream(id)) {
            (endpoint.child ? stream->child_closed : stream->origin_closed) = true;
            if (endpoint.child && error == NGHTTP2_NO_ERROR && stream->response.discard_body && stream->response.streaming && stream->origin_id && !stream->origin_closed && !stream->rejected) {
              stream->origin_canceled_for_head = true;
              nghttp2_submit_rst_stream(endpoint.owner->origin_.session, 0, stream->origin_id, NGHTTP2_CANCEL);
            }

            if (error != NGHTTP2_NO_ERROR && !endpoint.owner->closing_) {
              if (!endpoint.child && stream->origin_canceled_for_head) {
                endpoint.owner->capture_.observe(Http2Direction::response, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream->child_id)});
              } else {
                endpoint.owner->reject(*stream, "http2_stream_reset", error);
              }
            }
          }

          return 0;
        }

        inline static int notSent(nghttp2_session* /*session*/, const nghttp2_frame* frame, int /*error*/, void* context) noexcept {
          auto& endpoint = *static_cast<Endpoint*>(context);

          if (frame->hd.type != NGHTTP2_HEADERS) {
            return 0;
          }

          for (auto& slot : endpoint.owner->streams_.viewMut()) {
            auto* stream = tbc::raw(slot ? &slot.getMut() : nullptr);
            if ((stream == nullptr) || (endpoint.child ? stream->child_id : stream->origin_id) != frame->hd.stream_id) {
              continue;
            }

            (endpoint.child ? stream->child_closed : stream->origin_closed) = true;
            endpoint.owner->reject(*stream, "http2_headers_not_sent");
            break;
          }

          return 0;
        }

        Http2Memory<Local> memory;
        // The connection nghttp2's callbacks re-enter, held raw as nghttp2 holds this endpoint.
        Http2EndpointConnection* owner;
        bool child;
        nghttp2_session* session = nullptr;
        // What one read takes from the peer, erased as soon as nghttp2 has parsed it.
        ds::Array<std::uint8_t, io_bytes> input;
        // What nghttp2 last produced, [output_offset, output_size) still unsent. The storage is kept
        // for the next batch, and erased once a batch is sent.
        ds::Option<SensitiveAllocation<Local>> output;
        std::size_t output_size = 0;
        std::size_t output_offset = 0;
        StreamReadiness read_wait = StreamReadiness::readable, write_wait = StreamReadiness::writable;
        bool eof = false;
      };

      class Fields {
      public:
        struct Field {
          std::string_view name;
          std::string_view value;
        };

        inline explicit Fields(Secure& memory)
            : names_(memory),
              fields_(memory) {
          names_.reserve(HttpFields<Local>::maximum_fields + 4);
          fields_.reserve(HttpFields<Local>::maximum_fields + 4);
        }

        inline void add(Field field) {
          names_.emplace(names_.memory(), field.name);
          auto& lower = names_.backMut();

          std::ranges::transform(lower.view(), lower.dataMut(), asciiLower);
          fields_.push({reinterpret_cast<std::uint8_t*>(lower.dataMut()), reinterpret_cast<std::uint8_t*>(const_cast<char*>(field.value.data())), lower.size(), field.value.size(), NGHTTP2_NV_FLAG_NONE}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast,cppcoreguidelines-pro-type-const-cast): nghttp2_nv takes a field's text as mutable bytes, which it only reads
        }

        [[nodiscard]] inline auto bytes() const noexcept -> std::span<const nghttp2_nv> {
          return fields_;
        }

      private:
        ds::Vec<ds::String<Secure>, Secure> names_;
        ds::Vec<nghttp2_nv, Secure> fields_;
      };

    public:
      // The connection keeps the allocator, the capture and the control, region `a`, and copies the
      // flow's identity, so its events view the connection and not the flow.
      inline explicit Http2EndpointConnection(tbc::mut_a<Memory> memory, tbc::val_a<Capture> capture, tbc::val_a<traffic::HttpControl*> control, traffic::FlowEvent context)
          : budget_(memory, connection_bytes),
            memory_(budget_),
            secure_(memory_),
            capture_(std::move(capture)),
            control_(control),
            identity_(traffic::FlowIdentity::of(context)),
            child_(memory_, tbc::raw(this), true),
            origin_(memory_, tbc::raw(this), false),
            streams_() {}

      Http2EndpointConnection(const Http2EndpointConnection&) = delete;
      Http2EndpointConnection& operator=(const Http2EndpointConnection&) = delete;
      Http2EndpointConnection(Http2EndpointConnection&&) = delete;
      Http2EndpointConnection& operator=(Http2EndpointConnection&&) = delete;

      inline ~Http2EndpointConnection() {
        closing_ = true;
        // By index: what each stream does borrows this connection.
        for (std::size_t index = 0; index < streams_.size(); ++index) {
          if (auto* stream = tbc::raw(streams_[index] ? &streams_.atMut(index).getMut() : nullptr)) {
            cancel(stream->request);
            cancel(stream->response);
          }
        }

        child_.close();
        origin_.close();
        capture_.finish(Http2Direction::request);
        capture_.finish(Http2Direction::response);
      }

      template <ByteStream Child, ByteStream Origin>
      inline bool advance(Child& child, Origin& origin, TunnelReadiness readiness) noexcept {
        if (failed_) {
          return false;
        }

        bool active = false;

        for (unsigned round = 0; round < maximum_rounds; ++round) {
          bool progress = false;

          progress = send(true, child, readiness.child) || progress;
          progress = send(false, origin, readiness.origin) || progress;
          progress = receive(true, child, readiness.child) || progress;
          progress = receive(false, origin, readiness.origin) || progress;
          settleStreams();
          active |= progress;
          if (!progress || failed_) {
            break;
          }
        }

        if (drained()) {
          failed_ = true;
        }

        if (failed_) {
          child.halfClose();
          origin.halfClose();
        }

        return active;
      }

      [[nodiscard]] inline bool finished() const noexcept {
        return failed_;
      }

      [[nodiscard]] inline bool halfClosed() const noexcept {
        return child_.eof || origin_.eof;
      }

      [[nodiscard]] inline bool readsChild() const noexcept {
        return !failed_ && !child_.eof;
      }

      [[nodiscard]] inline bool readsOrigin() const noexcept {
        return !failed_ && !origin_.eof;
      }

      [[nodiscard]] inline std::uint32_t inflight() const noexcept {
        return static_cast<std::uint32_t>(std::ranges::count_if(streams_, [](const auto& stream) {
          return bool(stream);
        }));
      }

      [[nodiscard]] inline auto childInterest() const noexcept -> SocketInterest {
        return interest(child_);
      }

      [[nodiscard]] inline auto originInterest() const noexcept -> SocketInterest {
        return interest(origin_);
      }

      [[nodiscard]] inline auto deadline() const noexcept -> ds::Option<Time> {
        ds::Option<Time> result;

        for (const auto& stream : streams_) {
          if (!stream || stream->rejected) {
            continue;
          }

          for (const auto* half : {&stream->request, &stream->response}) {
            const auto next = halfDeadline(*half);
            if (next && (!result || *next < *result)) {
              result = next;
            }
          }
        }

        return result;
      }

    private:
      // Resolves each stream's interceptions and drops the streams both sides closed.
      inline void settleStreams() noexcept {
        // By index: what each stream does borrows this connection.
        for (std::size_t index = 0; index < streams_.size(); ++index) {
          auto* stream = tbc::raw(streams_[index] ? &streams_.atMut(index).getMut() : nullptr);
          if (stream == nullptr) {
            continue;
          }

          if (!stream->rejected) {
            resolve(stream->request);
            resolve(stream->response);
          }

          if (stream->child_closed && (stream->origin_closed || stream->origin_id == 0)) {
            streams_.atMut(index).reset();
          }
        }
      }

      // Whether a side ended or the origin went away, and nothing is left in flight or to send.
      [[nodiscard]] inline bool drained() const noexcept {
        const bool drained_origin = origin_.eof || (origin_.output_size == 0 && !nghttp2_session_want_write(origin_.session));

        return (origin_.eof || child_.eof || draining_) && inflight() == 0 && child_.output_size == 0 && !nghttp2_session_want_write(child_.session) && drained_origin;
      }

      // When the half's message is next due: its hook's deadline while one decides, the end of its
      // collection while it is buffered, and none otherwise.
      [[nodiscard]] inline ds::Option<Time> halfDeadline(const Half& half) const noexcept {
        const auto& interception = half.interception;
        if (interception.waiting()) {
          return interception.deadline(control_);
        }

        if (interception.policy().enabled && half.headers_complete && !half.ended && !half.streaming) {
          return interception.collectUntil();
        }

        return ds::none;
      }

      // An endpoint is named by its side, so a callback that reaches the connection lends nothing of it.
      inline auto side(bool child) noexcept -> Endpoint& {
        return child ? child_ : origin_;
      }

      inline static auto half(bool child, tbc::mut_a<Stream> stream) noexcept -> tbc::mut_a<Half> {
        return child ? stream.request : stream.response;
      }

      inline auto source(Half& half) noexcept -> Endpoint& {
        return half.message.response ? origin_ : child_;
      }

      inline auto target(Half& half) noexcept -> Endpoint& {
        return half.message.response ? child_ : origin_;
      }

      inline auto sourceId(Half& half) const noexcept -> std::int32_t {
        return half.message.response ? half.stream.origin_id : half.stream.child_id;
      }

      inline auto targetId(Half& half) const noexcept -> std::int32_t {
        return half.message.response ? half.stream.child_id : half.stream.origin_id;
      }

      inline auto context(const Half& half) const noexcept -> traffic::FlowEvent {
        return identity_.event(half.message.response ? traffic::Direction::inbound : traffic::Direction::outbound);
      }

      inline int beginHeaders(bool child, const nghttp2_frame& frame) {
        if (frame.hd.type != NGHTTP2_HEADERS) {
          return 0;
        }

        auto* stream = side(child).stream(frame.hd.stream_id);
        if ((stream == nullptr) && child && frame.headers.cat == NGHTTP2_HCAT_REQUEST && !draining_) {
          for (auto& slot : streams_.viewMut()) {
            if (slot) {
              continue;
            }

            slot = ds::makeBox<Stream>(memory_, memory_, frame.hd.stream_id);
            stream = tbc::raw(slot ? &slot.getMut() : nullptr);
            if (nghttp2_session_set_stream_user_data(side(child).session, frame.hd.stream_id, stream) != 0) {
              throw std::runtime_error{"Set HTTP/2 stream identity"};
            }

            break;
          }
        }

        if ((stream == nullptr) || stream->rejected) {
          return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }

        const bool head_request = stream->request.message.method == "HEAD";
        auto& half = Http2EndpointConnection::half(child, *stream);

        half.trailer_block = half.headers_complete;
        if (!half.trailer_block) {
          half.header_bytes = 0;
          half.message.headers.clear();
          half.message.status = 0;
          if (!child) {
            half.message.response_to_head = head_request;
          }
        }

        return 0;
      }

      inline void header(bool child, Stream& stream, std::string_view name, std::string_view value) {
        auto& half = Http2EndpointConnection::half(child, stream);
        if (name.size() + value.size() + 4 > HttpMessageLimits::head_bytes - half.header_bytes) {
          throw std::length_error{"HTTP/2 header limit"};
        }

        half.header_bytes += name.size() + value.size() + 4;
        const auto direction = child ? Http2Direction::request : Http2Direction::response;

        capture_.observe(direction, {.kind = child ? Http2Event::Kind::request_header : Http2Event::Kind::response_header, .stream = static_cast<std::uint32_t>(stream.child_id), .name = name, .value = value});
        if (half.trailer_block) {
          half.message.trailers.append(name, value);
          return;
        }

        if (name == ":method") {
          half.message.method.assign(value);
        } else if (name == ":path") {
          half.message.target.assign(value);
        } else if (name == ":scheme") {
          half.message.scheme.assign(value);
        } else if (name == ":authority") {
          half.message.authority.assign(value);
        } else if (name == ":status") {
          const auto status = parseHttpStatus(value);
          if (!status) {
            throw std::invalid_argument{"Invalid HTTP/2 status"};
          }

          half.message.status = *status;
        } else if (name.starts_with(':')) {
          throw std::invalid_argument{"Unsupported HTTP/2 pseudo field"};
        } else {
          half.message.headers.append(name, value);
        }
      }

      inline void frame(bool child, const nghttp2_frame& frame) {
        if (frame.hd.type == NGHTTP2_GOAWAY) {
          goaway(child, frame);
          return;
        }

        auto* stream = side(child).stream(frame.hd.stream_id);
        if ((stream == nullptr) || stream->rejected || (frame.hd.type != NGHTTP2_HEADERS && frame.hd.type != NGHTTP2_DATA)) {
          return;
        }

        auto& half = Http2EndpointConnection::half(child, *stream);
        if (frame.hd.type == NGHTTP2_HEADERS && !half.trailer_block && !headers(child, half, frame)) {
          return;
        }

        if ((frame.hd.flags & NGHTTP2_FLAG_END_STREAM) && !stream->rejected) {
          endStream(child, half);
        }
      }

      // A side stops taking streams: the origin's refuses the streams it will not answer, and the
      // other side is told.
      inline void goaway(bool child, const nghttp2_frame& frame) {
        draining_ = true;
        if (!child) {
          // By index: what each stream does borrows this connection.
          for (std::size_t index = 0; index < streams_.size(); ++index) {
            auto* stream = tbc::raw(streams_[index] ? &streams_.atMut(index).getMut() : nullptr);
            if (stream && (stream->origin_id == 0 || stream->origin_id > frame.goaway.last_stream_id)) {
              reject(*stream, "http2_origin_goaway", NGHTTP2_REFUSED_STREAM);
            }
          }
        }

        check(nghttp2_submit_goaway(side(!child).session, NGHTTP2_FLAG_NONE, child ? 0 : highest_forwarded_, frame.goaway.error_code, nullptr, 0));
      }

      // A half's head arrived whole; false when it was an interim response, which goes on apart.
      inline bool headers(bool child, Half& half, const nghttp2_frame& frame) {
        if (!child && half.message.status < first_successful_status) {
          informational(half);
          return false;
        }

        half.headers_complete = true;
        if (child) {
          completeRequestHead(half);
        }

        half.message.validateHttp2();
        const auto& policy = half.interception.select(control_, context(half));

        half.streaming = !policy.enabled;
        if (policy.enabled) {
          limitBody(child, half);
        }

        if (half.streaming && !half.stream.rejected) {
          forward(half, false);
        }

        if (child && policy.enabled && !half.streaming && !half.stream.rejected && ((frame.hd.flags & NGHTTP2_FLAG_END_STREAM) == 0)) {
          answerContinue(half);
        }

        return true;
      }

      // A request remembers whether it asked for a head only, and takes its authority from Host
      // when it names none.
      inline void completeRequestHead(Half& half) {
        half.stream.original_head = half.message.method == "HEAD";
        if (half.message.authority.empty()) {
          if (const auto host = half.message.headers.get("host")) {
            half.message.authority.assign(*host);
          }
        }
      }

      // Gives up intercepting a message whose body cannot be collected: one over the limit, a
      // tunnel's, or one that streams without end.
      inline void limitBody(bool child, Half& half) {
        if (const auto length = half.message.headers.get("content-length")) {
          if (const auto size = parseExact<std::uint64_t>(*length); size && *size > wire_body_bytes) {
            unavailable(half, "http2_body_limit");
          }
        }

        const auto status = half.message.status;
        const bool tunnel = child ? half.message.method == "CONNECT" : half.stream.request.message.method == "CONNECT" && status >= first_successful_status && status < first_redirection_status;
        if (tunnel || half.message.streamingBody()) {
          unavailable(half, tunnel ? "http2_tunnel_body" : "http2_streaming_body");
        }
      }

      // Answers the child's Expect: 100-continue itself, as the hook waits for the body it holds back.
      inline void answerContinue(Half& half) {
        if (half.message.expectation() != HttpExpectation::hundred_continue) {
          return;
        }

        Fields fields{secure_};

        fields.add({.name = ":status", .value = "100"});
        check(nghttp2_submit_headers(child_.session, NGHTTP2_FLAG_NONE, half.stream.child_id, nullptr, fields.bytes().data(), fields.bytes().size(), nullptr));
        half.message.headers.remove("expect");
      }

      inline void endStream(bool child, Half& half) {
        half.ended = true;
        capture_.observe(child ? Http2Direction::request : Http2Direction::response, {.kind = child ? Http2Event::Kind::request_finished : Http2Event::Kind::response_ended, .stream = static_cast<std::uint32_t>(half.stream.child_id), .status = half.message.status});
        if (half.streaming) {
          resume(half);
        } else {
          complete(half);
        }
      }

      inline void data(bool child, Stream& stream, std::span<const Byte> bytes, bool end) {
        auto& half = Http2EndpointConnection::half(child, stream);

        half.uncredited += bytes.size();
        capture_.observe(child ? Http2Direction::request : Http2Direction::response, {.kind = child ? Http2Event::Kind::request_body : Http2Event::Kind::response_body, .stream = static_cast<std::uint32_t>(stream.child_id), .bytes = bytes});
        if (half.discard_body && half.streaming) {
          credit(half, bytes.size());
          return;
        }

        if (bytes.size() > wire_body_bytes - half.queue.size()) {
          unavailable(half, "http2_body_limit");
        }

        if (stream.rejected) {
          return;
        }

        half.queue.append(bytes);
        if (!half.streaming && half.queue.size() == wire_body_bytes && !end) {
          unavailable(half, "http2_body_limit");
        }

        if (half.streaming) {
          resume(half);
        }
      }

      inline void complete(Half& half) {
        try {
          if (!half.message.bodyless()) {
            half.message.decodeBody(half.queue.readable());
          }

          if (!half.interception.begin(memory_, *control_, context(half), half.message)) {
            forward(half, false);
          }
        } catch (...) {
          unavailable(half, "http2_entity_unavailable");
        }
      }

      inline void resolve(Half& half) noexcept {
        using Outcome = HttpInterceptionSlot<Local>::Outcome;

        if (half.interception.waiting()) {
          try {
            const auto outcome = half.interception.poll(*control_, half.message);
            if (outcome == Outcome::pending) {
              return;
            }

            if (outcome == Outcome::rejected) {
              reject(half.stream, "http2_interception_rejected");
              return;
            }

            forward(half, outcome == Outcome::replaced);
          } catch (...) {
            reject(half.stream, "http2_invalid_decision");
          }
        } else if (half.headers_complete && !half.ended && !half.streaming && std::chrono::steady_clock::now() >= half.interception.collectUntil()) {
          unavailable(half, "http2_collection_timeout");
        }
      }

      inline void unavailable(Half& half, std::string_view reason) noexcept {
        if (half.stream.rejected) {
          return;
        }

        if (half.interception.policy().fail_closed) {
          reject(half.stream, reason);
          return;
        }

        half.interception.unavailable(control_, context(half), reason);
        half.streaming = true;
        try {
          if (!half.forwarded) {
            forward(half, false);
          }
        } catch (...) {
          reject(half.stream, "http2_forwarding_failed");
        }
      }

      inline void informational(Half& half) {
        if (++half.informational > maximum_informational) {
          reject(half.stream, "http2_informational_limit");
          return;
        }

        Fields fields{secure_};
        ds::Array<char, 3> status{};

        std::to_chars(status.dataMut(), status.dataMut() + status.size(), half.message.status);
        fields.add({.name = ":status", .value = {status.data(), status.size()}});
        for (const auto& field : half.message.headers.fields()) {
          fields.add({.name = field.name(), .value = field.value()});
        }

        check(nghttp2_submit_headers(child_.session, NGHTTP2_FLAG_NONE, half.stream.child_id, nullptr, fields.bytes().data(), fields.bytes().size(), nullptr));
      }

      inline void forward(Half& half, bool changed) {
        if (half.forwarded || half.stream.rejected) {
          return;
        }

        half.message.validateHttp2();
        const bool source_head = half.message.response_to_head;

        if (half.message.response) {
          changed |= source_head != half.stream.original_head;
          half.message.response_to_head = half.stream.original_head;
          half.discard_body = half.message.bodyless();
        }

        if (changed) {
          rewriteBody(half);
        }

        Fields fields{secure_};
        ds::Array<char, 3> status{};

        if (half.message.response) {
          std::to_chars(status.dataMut(), status.dataMut() + status.size(), half.message.status);
          fields.add({.name = ":status", .value = {status.data(), status.size()}});
        } else {
          fields.add({.name = ":method", .value = half.message.method});
          if (half.message.method != "CONNECT") {
            fields.add({.name = ":scheme", .value = half.message.scheme});
            fields.add({.name = ":path", .value = half.message.target});
          }

          fields.add({.name = ":authority", .value = half.message.authority});
        }

        for (const auto& field : half.message.headers.fields()) {
          fields.add({.name = field.name(), .value = field.value()});
        }

        nghttp2_data_provider2 provider{.source = {.ptr = &half}, .read_callback = &readBody};
        auto& endpoint = target(half);

        if (half.message.response) {
          check(nghttp2_submit_response2(endpoint.session, half.stream.child_id, fields.bytes().data(), fields.bytes().size(), half.message.bodyless() ? nullptr : &provider));
        } else {
          const auto id = nghttp2_submit_request2(endpoint.session, nullptr, fields.bytes().data(), fields.bytes().size(), &provider, &half.stream);

          check(id);
          half.stream.origin_id = id;
          highest_forwarded_ = std::max(highest_forwarded_, half.stream.child_id);
        }

        half.forwarded = true;
        half.message.response_to_head = source_head;
        if (half.discard_body) {
          half.queue.clear();
          credit(half, half.uncredited);
        }

        if (half.ended && !half.streaming) {
          credit(half, half.uncredited);
        }

        half.interception.release();
      }

      // Re-encodes the body a hook or a head change left the message with, and sets its length.
      inline void rewriteBody(Half& half) {
        half.queue.clear();
        const bool head_representation = half.message.response && half.message.response_to_head && !bodylessResponse(half.message.status, false);
        const bool materialized_head = head_representation && (half.message.body_materialized || !half.message.body.empty());
        if (!half.message.bodyless() || materialized_head) {
          const auto body = half.message.encodeBody();

          half.queue.append(body.bytes());
        }

        if (!head_representation || materialized_head) {
          half.message.headers.remove("content-length");
        }

        if (!half.message.bodyless() || half.message.status == reset_content_status || materialized_head) {
          // Room for the decimal digits of any length.
          constexpr std::size_t length_capacity = 32;

          ds::Array<char, length_capacity> length{};
          const auto digits = length.viewMut();
          const auto formatted = std::to_chars(digits.data(), std::to_address(digits.end()), half.queue.size());

          half.message.headers.append("content-length", {length.data(), static_cast<std::size_t>(formatted.ptr - digits.data())});
        }
      }

      // Returning DEFERRED parks only this data provider; nghttp2 can send every other stream.
      inline static nghttp2_ssize readBody(nghttp2_session* session, std::int32_t id, std::uint8_t* output, std::size_t capacity, std::uint32_t* flags, nghttp2_data_source* source, void* context) noexcept { // NOLINT(readability-function-size): nghttp2's read callback takes seven parameters
        auto& endpoint = *static_cast<Endpoint*>(context);
        auto& half = *static_cast<Half*>(source->ptr);
        if (half.stream.rejected) {
          return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }

        const auto bytes = half.queue.readable().first(std::min(capacity, half.queue.size()));
        if (bytes.empty() && !half.ended) {
          return NGHTTP2_ERR_DEFERRED;
        }

        // Measured first: consuming them ends the view of the queue.
        const auto count = bytes.size();

        std::ranges::copy(bytes, output);
        half.queue.consume(count);
        if (half.streaming) {
          endpoint.owner->credit(half, count);
        }

        if (half.queue.empty() && half.ended) {
          *flags |= NGHTTP2_DATA_FLAG_EOF;
          if (!half.message.trailers.fields().empty()) {
            try {
              Fields fields{endpoint.owner->secure_};

              for (const auto& field : half.message.trailers.fields()) {
                fields.add({.name = field.name(), .value = field.value()});
              }

              *flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
              check(nghttp2_submit_trailer(session, id, fields.bytes().data(), fields.bytes().size()));
            } catch (...) {
              endpoint.owner->reject(half.stream, "http2_trailer_failed");
              return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
          }
        }

        return static_cast<nghttp2_ssize>(count);
      }

      inline void credit(Half& half, std::size_t count) noexcept {
        count = std::min(count, half.uncredited);
        if (count != 0U) {
          nghttp2_session_consume_stream(source(half).session, sourceId(half), count);
          half.uncredited -= count;
        }
      }

      inline void resume(Half& half) noexcept {
        if (half.forwarded && !half.stream.rejected) {
          nghttp2_session_resume_data(target(half).session, targetId(half));
        }
      }

      inline void cancel(Half& half) noexcept {
        half.interception.cancel(control_);
      }

      inline void reject(Stream& stream, std::string_view reason, std::uint32_t code = NGHTTP2_CANCEL) noexcept {
        if (stream.rejected) {
          return;
        }

        stream.rejected = true;
        cancel(stream.request);
        cancel(stream.response);
        if (!stream.child_closed) {
          nghttp2_submit_rst_stream(child_.session, NGHTTP2_FLAG_NONE, stream.child_id, code);
        }

        if (stream.origin_id && !stream.origin_closed) {
          nghttp2_submit_rst_stream(origin_.session, NGHTTP2_FLAG_NONE, stream.origin_id, code);
        }

        auto event = identity_.event();

        event.reason = reason;
        if (control_ != nullptr) {
          control_->httpUnavailable(event);
        }

        capture_.observe(Http2Direction::request, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream.child_id)});
        capture_.observe(Http2Direction::response, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream.child_id)});
      }

      template <ByteStream Source>
      inline bool receive(bool child, Source& source, SocketInterest readiness) noexcept {
        if (side(child).eof || !readiness.satisfies(side(child).read_wait)) {
          return false;
        }

        auto& input = side(child).input;
        const auto read = source.read(input.viewMut());
        if (read.state == StreamResult::State::blocked) {
          side(child).read_wait = read.waiting;
          return false;
        }

        if (read.state == StreamResult::State::ended || read.state == StreamResult::State::failed) {
          side(child).eof = true;
          if (!child) {
            closeOrigin();
          }

          return true;
        }

        side(child).read_wait = StreamReadiness::readable;
        // The session calls back into this connection while it parses the input.
        const auto consumed = nghttp2_session_mem_recv2(side(child).session, input.data(), read.bytes);

        eraseSensitive(input.dataMut(), read.bytes);
        if (consumed < 0 || static_cast<std::size_t>(consumed) != read.bytes) {
          fail("http2_connection_failed");
        }

        return read.bytes != 0;
      }

      // The origin ended: nothing more is sent to it, and every stream it left open fails.
      inline void closeOrigin() noexcept {
        draining_ = true;
        origin_.output.reset();
        origin_.output_size = 0;
        // By index: what each stream does borrows this connection.
        for (std::size_t index = 0; index < streams_.size(); ++index) {
          if (auto* stream = tbc::raw(streams_[index] ? &streams_.atMut(index).getMut() : nullptr); stream && !stream->origin_closed) {
            reject(*stream, "http2_origin_closed");
          }
        }
      }

      template <ByteStream Destination>
      inline bool send(bool child, Destination& destination, SocketInterest readiness) noexcept {
        auto& endpoint = side(child);
        if (endpoint.eof && !endpoint.child) {
          return false;
        }

        if (!readiness.satisfies(endpoint.write_wait)) {
          return false;
        }

        try {
          if (endpoint.output_size == 0) {
            const std::uint8_t* bytes = nullptr;
            const auto size = nghttp2_session_mem_send2(endpoint.session, &bytes);
            if (size < 0) {
              fail("http2_output_failed");
              return false;
            }

            if (size == 0) {
              return false;
            }

            if (!endpoint.output || endpoint.output->bytes().size() < static_cast<std::size_t>(size)) {
              endpoint.output.emplace(memory_, static_cast<std::size_t>(size));
            }

            std::copy_n(bytes, size, endpoint.output.getMut().bytesMut().data());
            endpoint.output_size = static_cast<std::size_t>(size);
            endpoint.output_offset = 0;
          }

          const auto result = destination.write(endpoint.output->bytes().subspan(endpoint.output_offset, endpoint.output_size - endpoint.output_offset));
          if (result.state == StreamResult::State::blocked) {
            endpoint.write_wait = result.waiting;
            return false;
          }

          if (result.state != StreamResult::State::data || result.bytes == 0) {
            fail("http2_socket_write_failed");
            return false;
          }

          endpoint.write_wait = StreamReadiness::writable;
          endpoint.output_offset += result.bytes;
          if (endpoint.output_offset == endpoint.output_size) {
            eraseSensitive(endpoint.output.getMut().bytesMut().data(), endpoint.output_size);
            endpoint.output_size = 0;
          }

          return true;
        } catch (...) {
          fail("http2_output_limit");
          return false;
        }
      }

      inline static auto interest(const Endpoint& endpoint) noexcept -> SocketInterest {
        SocketInterest result;

        if (!endpoint.eof) {
          result.include(endpoint.read_wait);
        }

        if ((!endpoint.eof || endpoint.child) && (endpoint.output_size != 0 || nghttp2_session_want_write(endpoint.session))) {
          result.include(endpoint.write_wait);
        }

        return result;
      }

      inline static void check(int result) {
        if (result < 0) {
          throw std::runtime_error{nghttp2_strerror(result)};
        }
      }

      inline void fail(std::string_view reason) noexcept {
        if (failed_) {
          return;
        }

        failed_ = true;
        auto event = identity_.event();

        event.reason = reason;
        if (control_ != nullptr) {
          control_->httpUnavailable(event);
        }
      }

      static constexpr unsigned maximum_rounds = 8, maximum_informational = 8;
      tbc::val_a<BudgetAllocator<Memory>> budget_;
      tbc::val_a<Local> memory_;
      tbc::val_a<Secure> secure_;
      tbc::val_a<Capture> capture_;
      tbc::val_a<traffic::HttpControl*> control_;
      traffic::FlowIdentity identity_;
      // Each endpoint's session calls back into this connection, so it stays where it was built.
      tbc::val_a<Endpoint> child_, origin_;
      tbc::val_a<ds::Array<ds::Box<Stream, Local>, maximum_streams>> streams_;
      std::int32_t highest_forwarded_ = 0;
      bool failed_ = false, closing_ = false, draining_ = false;
    };

  }
}

// Interface: proxy/stream_prefix.cppm
export {
  namespace telar::runtime {

    class StreamPrefix {
    public:
      static constexpr std::size_t capacity = 8192;

      // Generic over the caller's streams, and called for every read the relay makes.
      template <ByteStream Stream>
      TBC_GENERIC StreamResult fill(Stream& stream) noexcept {
        const auto result = stream.read(storage_.bytes().subspan(length_));
        if (result.state == StreamResult::State::data) {
          length_ += result.bytes;
        }

        return result;
      }

      std::span<const std::uint8_t> bytes() noexcept;

      [[nodiscard]] bool empty() const noexcept;

      void consume(std::size_t count) noexcept;

    private:
      SensitiveBuffer<capacity> storage_;
      std::size_t offset_ = 0;
      std::size_t length_ = 0;
    };

    // Generic over the caller's stream, and called for every read the relay makes.
    template <PeekableByteStream Stream>
    class TBC_GENERIC PrefixedStream {
    public:
      inline explicit PrefixedStream(Stream& stream, StreamPrefix& prefix) noexcept
          : stream_(stream),
            prefix_(prefix) {}

      inline StreamResult read(std::span<std::uint8_t> bytes) noexcept {
        if (prefix_.empty()) {
          return stream_.read(bytes);
        }

        const auto count = std::min(prefix_.bytes().size(), bytes.size());

        std::memcpy(bytes.data(), prefix_.bytes().data(), count);
        prefix_.consume(count);
        return {.state = StreamResult::State::data, .bytes = count};
      }

      inline StreamResult peek(std::span<std::uint8_t> bytes) noexcept {
        if (prefix_.empty()) {
          return stream_.peek(bytes);
        }

        const auto count = std::min(prefix_.bytes().size(), bytes.size());

        std::memcpy(bytes.data(), prefix_.bytes().data(), count);
        return {.state = StreamResult::State::data, .bytes = count};
      }

      inline StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
        return stream_.write(bytes);
      }

      inline void halfClose() noexcept {
        stream_.halfClose();
      }

    private:
      Stream& stream_;
      StreamPrefix& prefix_;
    };

  }
}

// Interface: proxy/application_relay.cppm
export {
  namespace telar::runtime {

    class ApplicationRelay {
    public:
      // The relays it builds keep the allocator and the observation it was given, region `a`, which
      // outlives the relay. The relay copies the host, and is lent the flow on each advance.
      explicit ApplicationRelay(tbc::mut_a<ConcurrentMemory> memory, tbc::val_a<ConnectionObservation> observation, std::string_view hostname);

      void select(HttpProtocol protocol, bool unnegotiated) noexcept;

      // Generic over the caller's streams, and called for every read the relay makes.
      template <PeekableByteStream Child, PeekableByteStream Origin>
      TBC_GENERIC auto advance(Child& child_stream, Origin& origin_stream, TunnelReadiness readiness, FlowState* flow) noexcept -> bool {
        bool active = false;

        if (!protocol_) {
          active = sniff(child_stream, origin_stream);
          if (!protocol_) {
            return active;
          }
        }

        PrefixedStream prefixed{child_stream, prefix_};
        FlowStream child{prefixed, flow, traffic::Direction::inbound};
        FlowStream origin{origin_stream, flow, traffic::Direction::outbound};

        if (active) {
          readiness = TunnelReadiness::available();
        }

        return relays_.transfer(*protocol_, child, origin, readiness, flow) || active;
      }

      [[nodiscard]] auto finished() const noexcept -> bool;

      [[nodiscard]] auto halfClosed() const noexcept -> bool;

      [[nodiscard]] auto idle() const noexcept -> bool;

      [[nodiscard]] auto inflight() const noexcept -> std::uint32_t;

      [[nodiscard]] auto buffered() const noexcept -> bool;

      [[nodiscard]] auto readsChild() const noexcept -> bool;

      [[nodiscard]] auto readsOrigin() const noexcept -> bool;

      [[nodiscard]] auto deadline() const noexcept -> ds::Option<traffic::FlowControl::Time>;

      [[nodiscard]] auto interest(TlsSide side) const noexcept -> SocketInterest;

    private:
      using Http1 = Http1Connection<Http1Capture<>>;
      using Http2 = Http2Connection<ConcurrentMemory, Http2Capture<>>;
      using Http2Endpoint = Http2EndpointConnection<ConcurrentMemory, Http2Capture<>>;

      // Reads what the child sends first and tells its protocol by it, or by the origin speaking
      // first; whether anything was read.
      template <PeekableByteStream Child, PeekableByteStream Origin>
      TBC_GENERIC bool sniff(Child& child_stream, Origin& origin_stream) noexcept {
        const auto read = prefix_.fill(child_stream);
        const bool active = read.state == StreamResult::State::data;

        identify();
        ds::Array<Byte, Http2Frame::header_bytes> banner{};
        const auto origin = origin_stream.peek(banner.viewMut());

        if (!protocol_ && prefix_.empty() && (origin.state == StreamResult::State::data || origin.state == StreamResult::State::ended || origin.state == StreamResult::State::failed)) {
          identifyOrigin(banner.view().first(origin.bytes));
        }

        if (!protocol_ && (read.state == StreamResult::State::ended || read.state == StreamResult::State::failed)) {
          protocol_ = HttpProtocol::other;
        }

        return active;
      }

      // An origin that speaks first is HTTP/2 when it opens with its SETTINGS frame.
      void identifyOrigin(std::span<const Byte> banner) noexcept;

      void identify() noexcept;

      // What a child's first bytes say of HTTP/1: http11 or other once its request line tells, none
      // while it may still be one.
      static ds::Option<HttpProtocol> http1Request(std::string_view head) noexcept;

      // The relays and what they are built from, apart from the prefix a child stream drains: a transfer
      // lends the prefix to the stream and the relays to the call.
      struct Relays {
        // The start copies the host the relay keeps.
        [[nodiscard]] auto captureStart(CaptureProtocol protocol) const noexcept -> CaptureStart;

        // Generic over the caller's streams, and called for every read the relay makes.
        template <PeekableByteStream Child, PeekableByteStream Origin>
        TBC_GENERIC auto transfer(HttpProtocol protocol, Child& child, Origin& origin, TunnelReadiness readiness, FlowState* flow) noexcept -> bool {
          if (protocol == HttpProtocol::http2) {
            return transferHttp2(child, origin, readiness, flow);
          }

          if (protocol == HttpProtocol::http11) {
            if (!http1_ && !startHttp1(flow)) {
              return false;
            }

            if (!http1_->upgraded()) {
              const bool active = http1_.getMut().advance(child, origin, readiness);

              if (!http1_->upgraded()) {
                return active;
              }

              return duplex_.advance(child, origin, TunnelReadiness::available()) || active;
            }
          }

          return duplex_.advance(child, origin, readiness);
        }

        template <PeekableByteStream Child, PeekableByteStream Origin>
        TBC_GENERIC bool transferHttp2(Child& child, Origin& origin, TunnelReadiness readiness, FlowState* flow) noexcept {
          if (!http2_ && !http2_endpoint_) {
            try {
              Http2Capture<> capture{observation_.captures, observation_.counters, captureStart(CaptureProtocol::http2)};
              auto* control = observation_.flows != nullptr ? observation_.flows->http() : nullptr;
              if (control != nullptr) {
                const auto event = flow != nullptr ? flow->context() : traffic::FlowEvent{.id = observation_.identity, .host = hostname_.view()};

                http2_endpoint_ = ds::makeBox<Http2Endpoint>(memory_, memory_, std::move(capture), control, event);
              } else {
                http2_ = ds::makeBox<Http2>(memory_, memory_, observation_.counters, std::move(capture));
              }
            } catch (...) {
              failed_ = true;
              return false;
            }
          }

          return http2_endpoint_ ? http2_endpoint_.getMut().advance(child, origin, readiness) : http2_.getMut().advance(child, origin, readiness);
        }

        // Builds the HTTP/1 relay; false, and the relay failed, when it cannot be built.
        bool startHttp1(FlowState* flow) noexcept;

        tbc::mut_a<ConcurrentMemory> memory_;
        tbc::val_a<ConnectionObservation> observation_;
        FixedText<ProxyHostname::maximum_bytes> hostname_;
        tbc::val_a<ds::Box<Http1, ConcurrentMemory>> http1_;
        tbc::val_a<ds::Box<Http2, ConcurrentMemory>> http2_;
        tbc::val_a<ds::Box<Http2Endpoint, ConcurrentMemory>> http2_endpoint_;
        DuplexRelay<> duplex_;
        bool failed_ = false;
      };

      tbc::val_a<Relays> relays_;
      StreamPrefix prefix_;
      ds::Option<HttpProtocol> protocol_;
      traffic::FlowControl::Time sniff_until_;
      bool selected_ = false;
    };

  }
}

// Interface: proxy/plain_tunnel.cppm
export {
  namespace telar::runtime {

    class PlainTunnel {
    public:
      // The tunnel keeps the allocator and the observation, region `a`, and copies the host.
      explicit PlainTunnel(tbc::mut_a<ConcurrentMemory> memory, TunnelSockets sockets, std::string_view hostname, tbc::val_a<ConnectionObservation> observation);

      // `flow` is the connection's flow, or null when no hook watches it.
      bool advance(TunnelReadiness readiness, FlowState* flow) noexcept;

      [[nodiscard]] bool finished() const noexcept;

      [[nodiscard]] bool halfClosed() const noexcept;

      [[nodiscard]] bool idle() const noexcept;

      [[nodiscard]] std::uint32_t inflight() const noexcept;

      [[nodiscard]] bool buffered() const noexcept;

      [[nodiscard]] auto deadline() const noexcept;

      [[nodiscard]] SocketInterest interest(TlsSide side) const noexcept;

    private:
      TunnelSockets sockets_;
      tbc::val_a<ApplicationRelay> application_;
    };

  }
}

// Interface: proxy/tls_tunnel.cppm
export {
  namespace telar::runtime {

    class TlsTunnel {
    public:
      // The tunnel keeps the allocator, the interception and the observation, region `a`, and its session
      // and relay copy the host.
      // `offer` is the child's ClientHello when the handshake already read it, or null.
      explicit TlsTunnel(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<TlsInterception> interception, TunnelRoute route, tbc::val_a<ds::Box<AlpnOffer, ConcurrentMemory>> offer, tbc::val_a<ConnectionObservation> observation);

      // `flow` is the connection's flow, or null when no hook watches it.
      auto advance(TunnelReadiness readiness, FlowState* flow) noexcept -> bool;

      [[nodiscard]] auto deadline() const noexcept;

      [[nodiscard]] auto established() const noexcept -> bool;

      [[nodiscard]] auto finished() const noexcept -> bool;

      [[nodiscard]] auto halfClosed() const noexcept -> bool;

      [[nodiscard]] auto idle() const noexcept -> bool;

      [[nodiscard]] auto inflight() const noexcept -> std::uint32_t;

      [[nodiscard]] auto buffered() const noexcept -> bool;

      [[nodiscard]] auto interest(TlsSide side) const noexcept -> SocketInterest;

    private:
      tbc::val_static<std::string_view> recordFailure() noexcept;

      tbc::val_a<ConnectionObservation> observation_;
      tbc::val_a<ds::Box<TlsSession, ConcurrentMemory>> session_;
      tbc::val_a<ApplicationRelay> application_;
      bool failed_ = false;
    };

  }
}

// Interface: proxy/connection_transport.cppm
export {
  namespace telar::runtime {

    class ConnectionTransport {
    public:
      // The transport keeps the allocator, and the interception and observation it opens with, region `a`.
      explicit ConnectionTransport(tbc::mut_a<ConcurrentMemory> memory) noexcept;

      // Generic over the caller's resolver.
      template <HostnameResolver Resolver>
      TBC_GENERIC void open(tbc::ref_a<TlsInterception> interception, tbc::mut_a<ConnectHandshake<ConcurrentMemory, Resolver>> handshake, tbc::val_a<ConnectionObservation> observation) {
        const TunnelSockets sockets{handshake.childDescriptor(), handshake.originDescriptor()};

        if (observation.flows) {
          flow_ = ds::makeBox<FlowState>(memory_);
          flow_.getMut().open(observation.flows, observation.identity, sockets, handshake.hostname());
        }

        if (handshake.intercept()) {
          tls_ = ds::makeBox<TlsTunnel>(memory_, memory_, interception, TunnelRoute{.sockets = sockets, .hostname = handshake.hostname()}, handshake.takeOffer(), observation);
        } else {
          plain_ = ds::makeBox<PlainTunnel>(memory_, memory_, sockets, handshake.hostname(), observation);
          observation.counters.record(ProxyCounter::passthrough_connection);
        }
      }

      [[nodiscard]] bool opened() const noexcept;

      bool advance(TunnelReadiness readiness) noexcept;

      [[nodiscard]] bool established() const noexcept;

      [[nodiscard]] bool finished() const noexcept;

      [[nodiscard]] bool halfClosed() const noexcept;

      [[nodiscard]] bool idle() const noexcept;

      [[nodiscard]] std::uint32_t inflight() const noexcept;

      [[nodiscard]] bool buffered() const noexcept;

      [[nodiscard]] SocketInterest interest(TlsSide side) const noexcept;

      [[nodiscard]] ds::Option<traffic::FlowControl::Time> deadline() const noexcept;

      void reason(tbc::val_static<std::string_view> value) noexcept;

      void error(tbc::val_static<std::string_view> value) noexcept;

    private:
      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::val_a<ds::Box<FlowState, ConcurrentMemory>> flow_;
      tbc::val_a<ds::Box<PlainTunnel, ConcurrentMemory>> plain_;
      tbc::val_a<ds::Box<TlsTunnel, ConcurrentMemory>> tls_;
    };

  }
}

// Interface: proxy/observations.cppm
export {
  namespace telar::runtime {

    // What every connection reports to: the counters and the capture producer, which are shared, so an
    // observation it hands out stays valid whatever is done through it.
    class TBC_SHARED ProxyObservations {
    public:
      explicit ProxyObservations(ConcurrentMemory& memory, ProxyCaptureLimits limits, traffic::FlowControl* flows = nullptr);

      ConnectionObservation connection() noexcept;

      [[nodiscard]] const ProxyCounters& counters() const noexcept;

      ProxyCounters& countersMut() noexcept;

      [[nodiscard]] const CaptureProducer& captures() const noexcept;

      CaptureProducer& capturesMut() noexcept;

    private:
      ProxyCounters counters_;
      CaptureProducer captures_;
      bool capture_enabled_;
      traffic::FlowControl* flows_;
      std::uint64_t next_connection_ = 1;
    };

  }
}

// Interface: proxy/connection.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's resolver.
    template <HostnameResolver Resolver>
    class TBC_GENERIC ProxyConnection {
    public:
      using Time = ProxyConnectionPolicy::Time;

      // A connection keeps the allocator, the options, the secret and the counters of the service that
      // accepted it, and the interception and observations it advances through: region `a`.
      inline explicit ProxyConnection(tbc::mut_a<ConcurrentMemory> memory, FileDescriptor child, tbc::ref_a<ProxyOptions<ConcurrentMemory>> options, tbc::ref_a<ProxySecret> secret, tbc::mut_a<ProxyCounters> counters)
          : counters_(counters),
            handshake_(memory, std::move(child), options, secret, counters),
            transport_(memory),
            policy_(ProxyConnectionPolicy::Clock::now()) {}

      inline explicit ProxyConnection(tbc::mut_a<ConcurrentMemory> memory, redirect::Connection connection, tbc::ref_a<ProxyOptions<ConcurrentMemory>> options, tbc::ref_a<ProxySecret> secret, tbc::mut_a<ProxyCounters> counters)
          : counters_(counters),
            redirect_lifetime_(std::move(connection.lifetime)),
            handshake_(memory, std::move(connection), options, secret, counters),
            transport_(memory),
            policy_(ProxyConnectionPolicy::Clock::now()) {}

      inline void advance(tbc::ref_a<TlsInterception> interception, tbc::mut_a<ProxyObservations> observations, TunnelReadiness readiness, Time now) noexcept {
        if (closed_) {
          return;
        }

        if (!transport_.opened()) {
          if (!establish(interception, observations, readiness.origin.writable, now)) {
            return;
          }

          readiness = TunnelReadiness::available();
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
        if (closure != Closure::none) {
          transport_.reason("timeout");
        }

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

      [[nodiscard]] inline SocketInterest interest(TlsSide side) const noexcept {
        if (transport_.opened()) {
          return transport_.interest(side);
        }

        if (side == TlsSide::child) {
          return {.readable = handshake_.wantsChildRead(), .writable = handshake_.wantsChildWrite()};
        }

        return {.readable = handshake_.wantsOriginRead(), .writable = handshake_.wantsOriginWrite()};
      }

      [[nodiscard]] inline int descriptor(TlsSide side) const noexcept {
        return side == TlsSide::child ? handshake_.childDescriptor() : handshake_.originDescriptor();
      }

      [[nodiscard]] inline std::size_t originAttempt() const noexcept {
        return handshake_.originAttempt();
      }

      [[nodiscard]] inline bool closed() const noexcept {
        return closed_;
      }

      [[nodiscard]] inline bool buffered() const noexcept {
        return transport_.buffered();
      }

      [[nodiscard]] inline ds::Option<Time> deadline() const noexcept {
        const auto handshake = handshake_.deadline();
        const auto transport = transport_.deadline();

        return earliest(handshake, transport);
      }

      [[nodiscard]] inline const ProxyConnectionPolicy& policy() const noexcept {
        return policy_;
      }

    private:
      using Handshake = ConnectHandshake<ConcurrentMemory, Resolver>;
      using Phase = ProxyConnectionPolicy::Phase;

      // Advances the CONNECT handshake and opens the transport once it is established; whether the
      // transport opened now.
      inline bool establish(tbc::ref_a<TlsInterception> interception, tbc::mut_a<ProxyObservations> observations, bool origin_writable, Time now) noexcept {
        handshake_.advance(origin_writable, now);
        if (!observation_ && !handshake_.hostname().empty()) {
          observation_.emplace(observations.connection());
        }

        if (handshake_.state() == Handshake::State::closed) {
          if (observation_ && (observation_->flows != nullptr)) {
            observation_->flows->observeFlow(traffic::Kind::flow_error, {.id = observation_->identity, .host = handshake_.hostname(), .reason = handshake_.failure()});
          }

          closed_ = true;
          return false;
        }

        if (handshake_.state() != Handshake::State::reading && policy_.phase() == Phase::connect_head) {
          enter(Phase::establishing, now);
        }

        if (handshake_.state() != Handshake::State::established) {
          return false;
        }

        try {
          transport_.open(interception, handshake_, *observation_);
          return true;
        } catch (...) {
          if (handshake_.intercept()) {
            counters_.record(ProxyCounter::tls_context_failure);
          }

          transport_.error(handshake_.intercept() ? "tls_context_failed" : "transport_setup_failed");
          closed_ = true;
          return false;
        }
      }

      inline void enter(Phase phase, Time now) noexcept {
        if (policy_.phase() != phase) {
          policy_.enter(phase, now);
          policy_.touch(now);
        }
      }

      tbc::mut_a<ProxyCounters> counters_;
      FileDescriptor redirect_lifetime_;
      tbc::val_a<Handshake> handshake_;
      tbc::val_a<ConnectionTransport> transport_;
      ProxyConnectionPolicy policy_;
      tbc::val_a<ds::Option<ConnectionObservation>> observation_;
      bool closed_ = false;
    };

  }
}

// Interface: proxy/client_configuration.cppm
export {
  namespace telar::runtime {

    // What a child process is told to reach the proxy through. It shares the identity the proxy made
    // once it was ready, so a holder keeps no part of the proxy itself.
    class ProxyClientConfiguration {
    public:
      struct Identity {
        ProxyStatus status{};
        ProxySecret secret;
        bool https_proxy = true;
        FixedText<PATH_MAX> certificate;
        FixedText<PATH_MAX> bundle;
      };

      ProxyClientConfiguration() noexcept = default;

      explicit ProxyClientConfiguration(std::shared_ptr<const Identity> identity) noexcept;

      [[nodiscard]] const ProxyStatus& status() const noexcept;

      // The command takes each variable the child gets. Built in runtime.cpp for the allocators of
      // Command.
      template <Allocator Memory>
      void apply(Command<Memory>& command) const;

    private:
      void environment(void* target, void (*set)(void* target, std::string_view name, std::string_view value)) const;

      inline static const ProxyStatus inactive{};
      std::shared_ptr<const Identity> identity_;
    };

    extern template void ProxyClientConfiguration::apply(Command<Memory>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<ConcurrentMemory>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<SystemAllocator>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<BudgetAllocator<SystemAllocator>>& command) const;
    extern template void ProxyClientConfiguration::apply(Command<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& command) const;

  }
}

// Interface: proxy/port_range.cppm
export {
  namespace telar::runtime {

    struct ProxyPortRange {
      static constexpr std::uint16_t first = 45100;
      static constexpr std::uint16_t count = 128;
      using Set = std::bitset<count>;

      static constexpr bool contains(std::uint16_t port) noexcept {
        return port >= first && port < first + count;
      }
    };

  }
}

// Interface: proxy/listener.cppm
export {
  namespace telar::runtime {

    class ProxyListener {
    public:
      static ProxyListener bind(ds::Option<std::uint16_t> preferred, const ProxyPortRange::Set& reserved);

      [[nodiscard]] FileDescriptor accept() const;

      [[nodiscard]] int descriptor() const noexcept;

      [[nodiscard]] std::uint16_t port() const noexcept;

      void close() noexcept;

    private:
      explicit ProxyListener(FileDescriptor socket, std::uint16_t port) noexcept;

      static FileDescriptor openSocket();

      static NetworkAddress address(std::uint16_t port) noexcept;

      static ds::Option<ProxyListener> tryPort(std::uint16_t port, bool reclaim);

      static FileDescriptor listen(std::uint16_t port, bool reuse_closed);

      static bool answers(std::uint16_t port) noexcept;

      static constexpr int backlog = 128;
      static constexpr int probe_timeout_ms = 50;
      FileDescriptor socket_;
      std::uint16_t port_;
    };

  }
}

// Interface: proxy/port_memory.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class ProxyPortMemory {
    public:
      explicit ProxyPortMemory(Memory& memory, int directory, std::string_view endpoint, bool inherit_legacy);

      [[nodiscard]] ds::Option<std::uint16_t> preferred() const noexcept;

      [[nodiscard]] const ProxyPortRange::Set& reserved() const noexcept;

      [[nodiscard]] std::string_view filename() const noexcept;

      bool remember(std::uint16_t port) noexcept;

    private:
      struct Record {
        std::uint16_t port = 0;
        std::string_view endpoint;
      };

      struct DirectoryCloser {
        void operator()(DIR* directory) const noexcept;
      };

      void identify(std::string_view endpoint) noexcept;

      tbc::val_a<ds::Option<Record>> recall(std::string_view name, tbc::mut_a<ds::Vec<unsigned char, Memory>> bytes) const noexcept;

      // Generic over the caller's visitor.
      template <typename Visitor>
      TBC_GENERIC void scan(const Visitor& visit) const noexcept {
        try {
          FileDescriptor descriptor{::openat(directory_, ".", combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
          if (!descriptor) {
            return;
          }

          std::unique_ptr<DIR, DirectoryCloser> directory{::fdopendir(descriptor.get())};
          if (!directory) {
            return;
          }

          descriptor.release();

          ds::Vec<unsigned char, Memory> bytes{memory_};

          for (std::size_t scanned = 0; scanned < maximum_scanned_entries; ++scanned) {
            const auto* entry = ::readdir(directory.get()); // NOLINT(concurrency-mt-unsafe): the directory stream is this call's own, which no other thread reads
            if (entry == nullptr) {
              return;
            }

            const std::string_view name{entry->d_name};
            if (entry->d_type != DT_REG || name == filename() || !isPortFile(name)) {
              continue;
            }

            if (const auto record = recall(name, bytes)) {
              visit(entry->d_name, *record);
            }
          }
        } catch (...) {
          // A directory that cannot be read holds no port to reserve or reclaim.
          return;
        }
      }

      static bool isPortFile(std::string_view name) noexcept;

      static bool vanished(std::string_view endpoint) noexcept;

      static std::string_view trimCarriageReturns(std::string_view text) noexcept;

      static constexpr std::string_view file_prefix = "proxy-port-";
      static constexpr std::string_view hexadecimal = "0123456789abcdef";
      static constexpr std::string_view legacy_name = "proxy-port";
      static constexpr std::size_t digest_bytes = 8;
      static constexpr std::size_t filename_bytes = file_prefix.size() + (digest_bytes * 2);
      static constexpr std::size_t maximum_scanned_entries = 4096;
      static constexpr std::size_t maximum_record_bytes = 8 + PATH_MAX + 1;
      Memory& memory_;
      int directory_;
      ds::String<Memory> endpoint_;
      ds::Array<char, filename_bytes + 1> name_{};
      ProxyPortRange::Set reserved_;
      ds::Option<std::uint16_t> own_;
      ds::Option<std::uint16_t> legacy_;
    };

    extern template class ProxyPortMemory<Memory>;
    extern template class ProxyPortMemory<ConcurrentMemory>;

    template <Allocator Memory>
    ProxyPortMemory(Memory& memory, int directory, std::string_view endpoint, bool inherit_legacy) -> ProxyPortMemory<Memory>;

  }
}

// Interface: proxy/refusal.cppm
export {
  namespace telar::runtime {

    class ProxyRefusal {
    public:
      explicit ProxyRefusal(FileDescriptor socket, ProxyConnectionPolicy::Time now) noexcept;

      bool advance(ProxyConnectionPolicy::Time now) noexcept;

      [[nodiscard]] int descriptor() const noexcept;

      [[nodiscard]] SocketInterest interest() const noexcept;

      [[nodiscard]] ProxyConnectionPolicy::Time deadline() const noexcept;

    private:
      static constexpr auto drain_duration = std::chrono::milliseconds{20};
      FileDescriptor socket_;
      ProxyConnectionPolicy::Time deadline_;
      StaticReply response_{proxy_responses::service_unavailable_closing};
    };

  }
}

// Interface: proxy/service.cppm
export {
  namespace telar::runtime {

    // What a proxy service keeps for the connections it accepts: its options, its secret and its TLS
    // interception.
    struct ProxyServiceParts {
      const ProxyOptions<ConcurrentMemory>& options;
      const ProxySecret& secret;
      const TlsInterception& interception;
    };

    template <EventLoop Poller, HostnameResolver Resolver>
    // The proxy's worker thread. It keeps `this`, and the connections it accepts keep its options, its
    // secret and its observations, so it stays where it was built; other threads only stop it and read
    // atomics, which is audited here.
    // Generic over the caller's event loop and resolver.
    class TBC_SHARED TBC_GENERIC ProxyService {
    public:
      inline explicit ProxyService(ConcurrentMemory& memory, ProxyServiceParts parts, ProxyListener listener, traffic::FlowControl* flows = nullptr)
          : memory_(memory),
            options_(parts.options),
            secret_(parts.secret),
            interception_(parts.interception),
            listener_(std::move(listener)),
            observations_(memory, parts.options.capture, flows),
            poller_(memory),
            resolutions_(resolution_signal_),
            flows_(flows) {
        poller_.watch(listener_.descriptor(), listener_token);
        poller_.watch(stop_signal_.descriptor(), stop_token);
        poller_.watch(resolution_signal_.descriptor(), resolution_token);
        poller_.watch(adoption_signal_.descriptor(), adoption_token);
        if (flows_ != nullptr) {
          poller_.watch(flows_->descriptor(), flow_token);
        }

        worker_ = std::thread{
            [this] {
              run();
            },
        };
      }

      inline ~ProxyService() {
        stopping_.store(true, std::memory_order_release);
        stop_signal_.notify();
        worker_.join();
      }

      ProxyService(const ProxyService&) = delete;
      ProxyService& operator=(const ProxyService&) = delete;
      ProxyService(ProxyService&&) = delete;
      ProxyService& operator=(ProxyService&&) = delete;

      inline std::uint16_t port() const noexcept {
        return listener_.port();
      }

      inline const ProxyCounters& counters() const noexcept {
        return observations_.counters();
      }

      inline CaptureProducer& capturesMut() noexcept {
        return observations_.capturesMut();
      }

      inline const CaptureProducer& captures() const noexcept {
        return observations_.captures();
      }

      inline std::uint32_t active() const noexcept {
        return active_.load(std::memory_order_relaxed);
      }

      inline std::uint64_t limitDrops() const noexcept {
        return limit_drops_.load(std::memory_order_relaxed);
      }

      inline bool failed() const noexcept {
        return failed_.load(std::memory_order_acquire);
      }

      inline bool adopt(redirect::Connection connection) noexcept {
        if (stopping_.load(std::memory_order_acquire) || failed()) {
          return false;
        }

        const bool accepted = adoptions_.publish(std::move(connection));
        if (!accepted) {
          limit_drops_.fetch_add(1, std::memory_order_relaxed);
        }

        adoption_signal_.notify();
        return accepted;
      }

    private:
      using Policy = ProxyConnectionPolicy;
      using Time = Policy::Time;
      using Connection = ProxyConnection<Resolver>;

      struct Slot {
        inline explicit Slot(ds::Box<Connection, ConcurrentMemory> accepted, std::uint64_t generation) noexcept
            : connection(std::move(accepted)),
              child_generation(generation) {}

        ds::Box<Connection, ConcurrentMemory> connection;
        SocketWatch child;
        SocketWatch origin;
        std::uint64_t child_generation;
        std::uint64_t origin_generation = 0;
        std::size_t origin_attempt = 0;
      };

      inline void run() noexcept {
        setThreadName("telar.proxy");
        try {
          ds::Array<Event, Poller::event_capacity> ready{};
          auto reap_at = Policy::Clock::now() + reap_interval;

          while (!stopping_.load(std::memory_order_acquire)) {
            const auto now = Policy::Clock::now();
            auto wake_at = reap_at;

            if (const auto due = resumeAccepting(now)) {
              wake_at = std::min(wake_at, *due);
            }

            occupied_.forEach([&](std::size_t index) {
              wake_at = sweep(index, now, now >= reap_at, wake_at);
            });

            if (now >= reap_at) {
              reap_at = now + reap_interval;
            }

            dispatchAll(poller_.wait(wake_at - Policy::Clock::now(), ready.viewMut()));
          }
        } catch (const std::exception& error) {
          reportProxy("service", error.what());
          failed_.store(true, std::memory_order_release);
        } catch (...) {
          failed_.store(true, std::memory_order_release);
        }

        refusal_watch_.remove(poller_);
        refusal_.reset();
        occupied_.forEach([this](std::size_t index) {
          release(index);
        });

        adoptions_.close();
        poller_.remove(listener_.descriptor());
        listener_.close();
      }

      // Advances the refusal and takes the listener back once the backoff passed; when the loop must
      // wake for them, if it must.
      inline ds::Option<Time> resumeAccepting(Time now) {
        advanceRefusal(now);
        if (refusal_) {
          return refusal_->deadline();
        }

        if (accept_after_ == Time{}) {
          return ds::none;
        }

        if (now < accept_after_) {
          return accept_after_;
        }

        accept_after_ = {};
        poller_.readInterest(listener_.descriptor(), listener_token, true);
        return ds::none;
      }

      // Expires the slot's connection when `reap` says so, or advances one with work due; when the
      // loop must wake for it next, at `wake_at` at the latest.
      inline Time sweep(std::size_t index, Time now, bool reap, Time wake_at) {
        auto& slot = slots_.atMut(index);

        if (reap) {
          slot.getMut().connection.getMut().expire(now);
          advance(index, {}, now);
        } else if (slot->connection->buffered() || (slot->connection->deadline() && now >= *slot->connection->deadline())) {
          advance(index, TunnelReadiness::available(), now);
        }

        if (!slot) {
          return wake_at;
        }

        if (const auto deadline = slot->connection->deadline()) {
          wake_at = std::min(wake_at, *deadline);
        }

        return slot->connection->buffered() ? now : wake_at;
      }

      inline void dispatchAll(std::span<const Event> events) {
        for (const auto& event : events) {
          if (stopping_.load(std::memory_order_acquire)) {
            break;
          }

          dispatch(event, Policy::Clock::now());
        }
      }

      inline void dispatch(const Event& event, Time now) {
        if (event.token == listener_token) {
          if (!refusal_ && accept_after_ == Time{}) {
            accept(now);
          }
        } else if (event.token == stop_token) {
          stop_signal_.drain();
        } else if (event.token == resolution_token) {
          resolution_signal_.drain();
          occupied_.forEach([&](std::size_t index) {
            if (slots_[index]->connection->policy().phase() == Policy::Phase::establishing) {
              advance(index, {}, now);
            }
          });
        } else if (event.token == flow_token) {
          flows_->drain();
          occupied_.forEach([&](std::size_t index) {
            advance(index, TunnelReadiness::available(), now);
          });
        } else if (event.token == adoption_token) {
          adoptConnections(now);
        } else if (event.token == refusal_token) {
          if (refusal_watch_.matches(event)) {
            advanceRefusal(now);
          }
        } else {
          dispatchSlot(event, now);
        }
      }

      // Takes in each connection the redirect handed over.
      inline void adoptConnections(Time now) {
        adoption_signal_.drain();
        while (auto connection = adoptions_.tryReceive()) {
          const auto index = admit(now, true);
          if (!index) {
            continue;
          }

          try {
            keep(ds::makeBox<Connection>(memory_, memory_, std::move(connection.getMut()), options_, secret_, observations_.countersMut()), *index, now);
          } catch (...) {
            release(*index);
          }
        }
      }

      // Advances the connection whose socket the event names, when it still is that slot's.
      inline void dispatchSlot(const Event& event, Time now) noexcept {
        const auto index = (event.token >> side_bits) & slot_mask;
        auto& slot = slots_[index];
        if (slot && (slot->child.matches(event) || slot->origin.matches(event))) {
          TunnelReadiness readiness;
          auto& side = slot->origin.matches(event) ? readiness.origin : readiness.child;

          side = {.readable = event.kind == EventKind::readable, .writable = event.kind == EventKind::writable};
          advance(index, readiness, now);
        }
      }

      inline void accept(Time now) {
        TELAR_TRACE("proxy.acceptConnections");
        for (std::size_t accepted = 0; accepted < maximum_accept_batch; ++accepted) {
          FileDescriptor child;

          try {
            child = listener_.accept();
          } catch (const SystemError& error) {
            if (error.code() == EMFILE || error.code() == ENFILE || error.code() == ENOBUFS || error.code() == ENOMEM) {
              accept_after_ = now + descriptor_backoff;
              poller_.readInterest(listener_.descriptor(), listener_token, false);
            }

            return;
          }

          if (!child) {
            return;
          }

          const auto index = admit(now);
          if (!index) {
            refusal_.emplace(std::move(child), now);
            poller_.readInterest(listener_.descriptor(), listener_token, false);
            advanceRefusal(now);
            return;
          }

          try {
            auto connection = ds::makeBox<Connection>(memory_, memory_, std::move(child), options_, secret_, observations_.countersMut());

            keep(std::move(connection), *index, now);
          } catch (...) {
            release(*index);
          }
        }
      }

      inline void keep(ds::Box<Connection, ConcurrentMemory> connection, std::size_t index, Time now) {
        slots_.atMut(index).emplace(std::move(connection), nextGeneration());
        occupied_.insert(index);
        active_.fetch_add(1, std::memory_order_relaxed);
        advance(index, {}, now);
      }

      inline ds::Option<std::size_t> admit(Time now, bool authenticated = false) noexcept {
        std::size_t unauthenticated = 0;

        occupied_.forEach([&](std::size_t index) {
          unauthenticated += slots_[index]->connection->policy().phase() == Policy::Phase::connect_head;
        });

        if (!authenticated && unauthenticated >= Policy::maximum_unauthenticated) {
          if (const auto evicted = oldest(Policy::Closure::evict_head, now)) {
            release(*evicted);
            observations_.countersMut().record(ProxyCounter::unauthenticated_eviction);
          } else {
            observations_.countersMut().record(ProxyCounter::unauthenticated_refusal);
            return ds::none;
          }
        }

        if (const auto available = occupied_.firstUnused()) {
          return available;
        }

        for (const auto reason : {Policy::Closure::evict_head, Policy::Closure::evict_idle, Policy::Closure::evict_silent}) {
          if (const auto evicted = oldest(reason, now)) {
            release(*evicted);
            observations_.countersMut().record(ProxyCounter::eviction);
            return evicted;
          }
        }

        limit_drops_.fetch_add(1, std::memory_order_relaxed);
        return ds::none;
      }

      inline ds::Option<std::size_t> oldest(Policy::Closure reason, Time now) const noexcept {
        ds::Option<std::size_t> found;
        auto since = Time::max();

        occupied_.forEach([&](std::size_t index) {
          const auto& policy = slots_[index]->connection->policy();
          const auto started = reason == Policy::Closure::evict_head ? policy.since() : policy.active();
          if (policy.evictable(reason, now) && started < since) {
            since = started;
            found = index;
          }
        });

        return found;
      }

      inline void advance(std::size_t index, TunnelReadiness readiness, Time now) noexcept {
        auto& slot = slots_.atMut(index).getMut();

        slot.connection.getMut().advance(interception_, observations_, readiness, now);
        if (slot.connection->closed()) {
          release(index);
          return;
        }

        try {
          if (slot.origin_attempt != slot.connection->originAttempt()) {
            slot.origin_attempt = slot.connection->originAttempt();
            slot.origin_generation = nextGeneration();
          }

          slot.child.update(poller_, slot.connection->descriptor(TlsSide::child), token(index, slot.child_generation, TlsSide::child), slot.connection->interest(TlsSide::child));
          slot.origin.update(poller_, slot.connection->descriptor(TlsSide::origin), token(index, slot.origin_generation, TlsSide::origin), slot.connection->interest(TlsSide::origin));
        } catch (const std::exception& error) {
          reportProxy("watch", error.what());
          release(index);
        } catch (...) {
          release(index);
        }
      }

      inline void advanceRefusal(Time now) {
        if (!refusal_) {
          return;
        }

        if (refusal_.getMut().advance(now)) {
          refusal_watch_.remove(poller_);
          refusal_.reset();
          poller_.readInterest(listener_.descriptor(), listener_token, true);
        } else {
          refusal_watch_.update(poller_, refusal_->descriptor(), refusal_token, refusal_->interest());
        }
      }

      inline void release(std::size_t index) noexcept {
        auto& slot = slots_.atMut(index);
        if (slot) {
          slot.getMut().child.remove(poller_);
          slot.getMut().origin.remove(poller_);
          slot.reset();
          occupied_.erase(index);
          active_.fetch_sub(1, std::memory_order_relaxed);
        }
      }

      inline static std::uint64_t token(std::size_t index, std::uint64_t generation, TlsSide side) noexcept {
        return (generation << generation_shift) | (index << side_bits) | (side == TlsSide::origin ? 1U : 0U);
      }

      inline std::uint64_t nextGeneration() {
        if (generation_ == (std::numeric_limits<std::uint64_t>::max() >> generation_shift)) {
          throw SystemError{"Proxy event generations exhausted", EOVERFLOW};
        }

        return ++generation_;
      }

      static constexpr std::uint64_t listener_token = 1;
      static constexpr std::uint64_t stop_token = 2;
      static constexpr std::uint64_t resolution_token = 3;
      static constexpr std::uint64_t refusal_token = 4;
      static constexpr std::uint64_t adoption_token = 5;
      static constexpr std::uint64_t flow_token = 6;
      static constexpr unsigned side_bits = 1;
      static constexpr unsigned slot_bits = 8;
      static constexpr unsigned generation_shift = slot_bits + side_bits;
      static constexpr std::size_t slot_mask = Policy::capacity - 1;
      static constexpr std::size_t maximum_accept_batch = 32;
      static constexpr auto reap_interval = std::chrono::seconds{1};
      static constexpr auto descriptor_backoff = std::chrono::milliseconds{100};
      static constexpr std::size_t adoption_capacity = 32;
      static_assert(Policy::capacity == 1U << slot_bits);

      ConcurrentMemory& memory_;
      const ProxyOptions<ConcurrentMemory>& options_;
      const ProxySecret& secret_;
      const TlsInterception& interception_;
      ProxyListener listener_;
      ProxyObservations observations_;
      Poller poller_;
      CompletionSignal stop_signal_;
      CompletionSignal resolution_signal_;
      CompletionSignal adoption_signal_;
      DropChannel<redirect::Connection, adoption_capacity> adoptions_;
      NameResolutions<Resolver>::Notifications resolutions_;
      traffic::FlowControl* flows_;
      ds::Array<ds::Option<Slot>, Policy::capacity> slots_;
      SlotIndexes<Policy::capacity> occupied_;
      ds::Option<ProxyRefusal> refusal_;
      SocketWatch refusal_watch_;
      Time accept_after_;
      std::uint64_t generation_ = 0;
      std::atomic<std::uint32_t> active_ = 0;
      std::atomic<std::uint64_t> limit_drops_ = 0;
      std::atomic<bool> stopping_ = false;
      std::atomic<bool> failed_ = false;
      std::thread worker_;
    };

  }
}

// Interface: proxy/runtime.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's event loop, resolver and tap.
    template <EventLoop Poller, HostnameResolver Resolver, typename Tap = IgnoreCaptureTap>
      requires CaptureTap<Tap>
    class TBC_GENERIC ProxyRuntime {
    public:
      inline explicit ProxyRuntime(ConcurrentMemory& memory, const ProxyOptions<ConcurrentMemory>& options, std::string_view endpoint, bool inherit_legacy)
        requires std::same_as<Tap, IgnoreCaptureTap>
          : ProxyRuntime(memory, options, endpoint, inherit_legacy, ignored_tap) {}

      inline explicit ProxyRuntime(ConcurrentMemory& memory, const ProxyOptions<ConcurrentMemory>& options, std::string_view endpoint, bool inherit_legacy, Tap& tap)
          : memory_(memory),
            authority_directory_(directoryPath(memory, options)),
            certificate_path_(memory),
            bundle_path_(memory) {
        TELAR_TRACE("proxy.startRuntime");
        const auto& path = authority_directory_;
        const proxy_trust::Paths trust_paths{memory, path};
        struct stat record_state{};
        const auto record_path = trust_paths.file(proxy_trust::Record::filename);
        const bool has_trust_record = ::lstat(record_path.data(), &record_state) == 0;
        if (!options.enabled && !has_trust_record) {
          return;
        }

        library_.emplace(memory);
        const auto destination = trust_paths.nativeDestination(memory, process_environment);
        proxy_trust::SystemCommand trust_command{memory, stderr};
        proxy_trust::Service system_trust{memory, *library_, trust_paths, trust_command, destination};
        if (const auto rotated = system_trust.rotateIfNeeded()) {
          reportProxy("trust", "installed ", {rotated->fingerprint.data(), rotated->fingerprint.size()});
        }

        const bool system_trusted = system_trust.inspect().status == proxy_trust::Status::installed;

        if (!options.enabled) {
          return;
        }

        raiseDescriptorLimit();
        createPrivateDirectory(path);
        FileDescriptor directory{::open(path.data(), combineFlags(O_DIRECTORY, O_RDONLY, O_NOFOLLOW, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
        if (!directory) {
          throw SystemError{"Open proxy authority directory"};
        }

        const auto authority_kind = system_trusted ? AuthorityKind::system_trust : AuthorityKind::private_local;
        auto authority = std::allocate_shared<CertificateAuthority>(AllocatorRef<CertificateAuthority, ConcurrentMemory>{memory}, CertificateAuthority::loadOrCreate(memory, *library_, directory.get(), authority_kind));

        publishAuthority(*authority, directory.get());
        trust_.emplace(memory, *library_);
        SystemCertificates::read([this](std::span<const std::uint8_t> bytes) {
          trust_.getMut().addDer(bytes);
        });

        contexts_.emplace(memory, *library_, *trust_);
        interception_.emplace(*contexts_, std::move(authority));
        secret_.emplace(ProxySecretFile::ensure(memory, directory.get()));
        ProxyPortMemory ports{memory, directory.get(), endpoint, inherit_legacy};
        auto listener = ProxyListener::bind(ports.preferred(), ports.reserved());

        ports.remember(listener.port());

        certificate_path_.assign(path);
        certificate_path_.push('/');
        certificate_path_.append(active_certificate);
        bundle_path_.assign(path);
        bundle_path_.append("/ca-bundle.pem");
        status_.active = true;
        status_.system_trusted = system_trusted;
        status_.port = listener.port();
        status_.preferred_port = ports.preferred();
        status_.scope = std::ranges::any_of(options.intercept_hosts.patterns(), [](const auto& host) {
          return host.view().starts_with('*');
        })
                            ? ProxyScope::wildcard
                            : ProxyScope::exact;
        using Identity = ProxyClientConfiguration::Identity;
        auto identity = std::allocate_shared<Identity>(AllocatorRef<Identity, ConcurrentMemory>{memory}, Identity{.status = status_, .secret = *secret_, .https_proxy = options.pane_https_proxy});

        identity->certificate.assign(certificate_path_);
        identity->bundle.assign(bundle_path_);
        client_ = std::move(identity);
        service_.emplace(memory, ProxyServiceParts{.options = options, .secret = *secret_, .interception = *interception_}, std::move(listener), flowControl(tap));
        if (options.transparent_redirect) {
          ds::String<ConcurrentMemory> redirect_path{memory, endpoint};

          redirect_path.append(redirect::socket_suffix);
          redirect_.emplace(redirect_path, service_.getMut());
        }

        if (options.capture.enabled) {
          captures_.emplace(memory, service_.getMut().capturesMut(), options.capture, tap);
        }
      }

      inline ProxyClientConfiguration clientConfiguration() const noexcept {
        return ProxyClientConfiguration{client_};
      }

      inline int descriptor() const noexcept {
        return captures_ ? captures_->descriptor() : -1;
      }

      inline bool collect() noexcept {
        return captures_ && captures_.getMut().collect();
      }

      inline CaptureMetrics captureMetrics() const noexcept {
        return service_ ? service_->captures().metrics() : CaptureMetrics{};
      }

      inline ProxyMetrics proxyMetrics() const noexcept {
        if (!service_) {
          return {};
        }

        return {service_->counters().snapshot(), service_->active(), service_->limitDrops()};
      }

      inline redirect::MonitorState redirectStatus() const noexcept {
        return redirect_ ? redirect_->status() : redirect::MonitorState::idle;
      }

      inline void stopRedirect() noexcept {
        if (redirect_) {
          redirect_.getMut().stop();
        }
      }

      struct AuthorityStatus {
        // The hexadecimal digits of a SHA-1 and of a SHA-256 digest.
        static constexpr std::size_t sha1_digits = 40;
        static constexpr std::size_t sha256_digits = 64;

        bool active = false;
        bool accepting = false;
        proxy_trust::Status trust = proxy_trust::Status::absent;
        ds::Array<char, sha1_digits> fingerprint_sha1{};
        ds::Array<char, sha256_digits> fingerprint_sha256{};
        ds::Array<Byte, PemDocument::maximum_bytes> certificate{};
        std::size_t certificate_bytes = 0;
      };

      inline AuthorityStatus authorityStatus(bool include_certificate = false) const {
        AuthorityStatus result;

        if (!interception_) {
          return result;
        }

        const proxy_trust::Paths paths{memory_, authority_directory_};
        const auto destination = paths.nativeDestination(memory_, process_environment);
        const auto inspection = proxy_trust::inspect(memory_, *library_, paths, destination);
        const auto current = interception_->snapshot();

        requireTls(current != nullptr, "TLS authority is unavailable");
        const auto& authority = *current;

        result.active = true;
        result.accepting = !interception_->suspended();
        result.trust = inspection.status;
        result.fingerprint_sha1 = authority.fingerprint();
        result.fingerprint_sha256 = authority.fingerprintSha256();
        if (inspection.record && inspection.record->fingerprint != result.fingerprint_sha1) {
          result.trust = proxy_trust::Status::stale;
        }

        if (include_certificate) {
          const PemDocument certificate{authority.certificate()};

          std::ranges::copy(certificate.bytes(), result.certificate.viewMut().begin());
          result.certificate_bytes = certificate.bytes().size();
        }

        return result;
      }

      // Keep each handshake's signer alive independently. If store or file updates
      // fail, new TLS sessions remain suspended until an explicit retry synchronizes
      // the signer and the stable trust files used by newly launched processes.
      template <proxy_trust::TrustCommandExecutor Executor>
      inline void manageAuthority(proxy_trust::Action action, Executor& executor) {
        if (!interception_) {
          throw std::invalid_argument{"Proxy TLS is disabled"};
        }

        const proxy_trust::Paths paths{memory_, authority_directory_};
        const auto destination = paths.nativeDestination(memory_, process_environment);
        proxy_trust::Service trust{memory_, *library_, paths, executor, destination};
        const auto previous = trust.inspect();
        if (previous.status == proxy_trust::Status::stale && !previous.record) {
          throw std::invalid_argument{"Proxy trust record is invalid"};
        }

        interception_.getMut().suspend(true);
        const auto directory = paths.prepare();
        auto kind = AuthorityKind::private_local;

        if (action == proxy_trust::Action::uninstall) {
          if (previous.record) {
            trust.uninstall(*previous.record);
          }
        } else if (action == proxy_trust::Action::install || previous.record) {
          trust.install(previous.record, action == proxy_trust::Action::rotate);
          kind = AuthorityKind::system_trust;
        } else {
          proxy_trust::PreparedAuthority prepared{memory_, *library_, directory.get(), proxy_trust::AuthorityPreparation{.kind = AuthorityKind::private_local, .force_rotation = true}};

          prepared.activate();
          prepared.commit();
        }

        auto authority = std::allocate_shared<CertificateAuthority>(AllocatorRef<CertificateAuthority, ConcurrentMemory>{memory_}, CertificateAuthority::loadOrCreate(memory_, *library_, directory.get(), kind));

        publishAuthority(*authority, directory.get());
        interception_.getMut().replace(std::move(authority));
        interception_.getMut().suspend(false);
      }

    private:
      static constexpr std::string_view active_certificate = "ca-active-cert.pem";

      inline void publishAuthority(const CertificateAuthority& authority, int directory) {
        const PemDocument certificate{authority.certificate()};
        if (const auto error = writePrivateFile(directory, active_certificate, certificate.bytes(), PrivateFileMode::replace)) {
          throw SystemError{"Publish active TLS certificate", error};
        }

        authority.writeBundle(directory, SystemRootBundle{memory_}.bytes());
      }

      inline static traffic::FlowControl* flowControl(Tap& tap) noexcept {
        if constexpr (requires { tap.flowControl(); }) {
          return tap.flowControl();
        }

        return nullptr;
      }

      inline static tbc::val_a<ds::String<ConcurrentMemory>> directoryPath(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<ProxyOptions<ConcurrentMemory>> options) {
        if (!options.authority_directory.empty()) {
          return options.authority_directory.clone();
        }

        return proxyAuthorityDirectory(memory, process_environment);
      }

      inline static void raiseDescriptorLimit() noexcept {
        constexpr rlim_t descriptors_per_connection = 2;
        constexpr rlim_t reserved_descriptors = 448;
        constexpr rlim_t wanted = (ProxyConnectionPolicy::capacity * descriptors_per_connection) + NameResolutions<Resolver>::capacity + reserved_descriptors;
        constexpr rlim_t descriptor_limit = 1024;
        static_assert(wanted == descriptor_limit);
        rlimit limit;
        if (::getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < wanted) {
          limit.rlim_cur = std::min(limit.rlim_max, wanted);
          ::setrlimit(RLIMIT_NOFILE, &limit);
        }
      }

      ConcurrentMemory& memory_;
      ds::String<ConcurrentMemory> authority_directory_;
      ds::String<ConcurrentMemory> certificate_path_;
      ds::String<ConcurrentMemory> bundle_path_;
      ProxyStatus status_{};
      ds::Option<TlsLibrary> library_;
      ds::Option<TlsTrustStore> trust_;
      ds::Option<TlsContexts> contexts_;
      ds::Option<TlsInterception> interception_;
      ds::Option<ProxySecret> secret_;
      std::shared_ptr<const ProxyClientConfiguration::Identity> client_;
      ds::Option<ProxyService<Poller, Resolver>> service_;
      ds::Option<CapturePipeline<Tap>> captures_;
      ds::Option<redirect::Ingress<ProxyService<Poller, Resolver>>> redirect_;
      inline static IgnoreCaptureTap ignored_tap;
    };

  }
}
