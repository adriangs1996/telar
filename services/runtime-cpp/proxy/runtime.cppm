module;
#include "tbc/view.hpp"
#include <errno.h>
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <unistd.h>

#include <cstdint>

#include <cstring>
#include <cstddef>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>
#include <cassert>


#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <cerrno>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <csignal>
#endif
#if (defined(__linux__))
#include <fcntl.h>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif


#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include <cstdio>
#include <netdb.h>

#include <nghttp2/nghttp2.h>

#include <brotli/encode.h>

#include <arpa/inet.h>

#include <stdlib.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/crypto.h>
#include <ctime>
#include <limits.h>
#include <sys/stat.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif

#include <pthread.h>


#include <sys/types.h>


#include <poll.h>

#include <openssl/sha.h>
#include <dirent.h>


#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#include <sys/un.h>
#include <sys/uio.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/resource.h>

export module telar.runtime.proxy.runtime;

import std;

export import telar.runtime.exchange_capture.exchange;
export import telar.runtime.exchange_capture.pipeline;
export import telar.runtime.exchange_capture.producer;
export import telar.runtime.http1.intercepted_relay;
export import telar.runtime.proxy.http2_capture_streams;
export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.platform.system_certificates;
export import telar.runtime.traffic.control_protocol;
export import telar.runtime.proxy.relay_direction;
export import telar.base.memory;
export import telar.runtime.http2.direction_observer;
export import telar.runtime.http.message;
export import telar.runtime.http2.frame_reader;
export import telar.runtime.tls.interception;
export import telar.runtime.platform.launch_program;
export import telar.runtime.proxy.authenticate;
export import telar.platform;
export import telar.runtime.redirect.ingress;
export import telar.runtime.tls.system_root_bundle;
export import telar.tls;
import telar.base.diagnostics;
import telar.platform.primitives;
import telar.client.protocol;

// Interface: proxy/http1_capture_policy.cppm
export {
namespace telar::runtime {

template <typename Capture>
concept Http1CapturePolicy = requires(Capture &capture, CaptureSide side, std::string_view head, std::span<const std::uint8_t> body, std::uint16_t status) {
  { capture.begin() } noexcept -> std::same_as<void>;
  { capture.head(side, head) } noexcept -> std::same_as<void>;
  { capture.payload(side, body) } noexcept -> std::same_as<void>;
  { capture.finishRequest() } noexcept -> std::same_as<void>;
  { capture.finishResponse(status) } noexcept -> std::same_as<void>;
  { capture.discardInformational() } noexcept -> std::same_as<void>;
  { capture.fail() } noexcept -> std::same_as<void>;
};

struct IgnoreHttp1Capture {
  inline void begin() noexcept {}
  inline void head(CaptureSide, std::string_view) noexcept {}
  inline void payload(CaptureSide, std::span<const std::uint8_t>) noexcept {}
  inline void finishRequest() noexcept {}
  inline void finishResponse(std::uint16_t) noexcept {}
  inline void discardInformational() noexcept {}
  inline void fail() noexcept {}
};

static_assert(Http1CapturePolicy<IgnoreHttp1Capture>);

}
}

// Interface: proxy/http1_capture.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http1Capture {
public:
  inline explicit Http1Capture(Memory &memory, CaptureProducer<Memory> *producer, CaptureStart context) noexcept
      : producer_(producer), context_(context), exchange_(memory) {}

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
    if (auto &half = select(side)) {
      half->appendHead(bytes);
    }
  }

  inline void payload(CaptureSide side, std::span<const std::uint8_t> bytes) noexcept {
    if (auto &half = select(side)) {
      half->append(half->bodyPart(), bytes);
    }
  }

  inline void finishRequest() noexcept {
    finish(CaptureSide::request, CaptureOutcome::finished);
  }

  inline void finishResponse(std::uint16_t status, bool complete = true) noexcept {
    if (exchange_.response) {
      exchange_.response->status_code = status;
    }
    finish(CaptureSide::response, !complete || status >= 400 ? CaptureOutcome::failed : CaptureOutcome::finished);
  }

  inline void discardInformational() noexcept {
    if (exchange_.response) {
      exchange_.response->head.reset();
    }
  }

  inline void fail() noexcept {
    finish(CaptureSide::request, CaptureOutcome::failed);
    finish(CaptureSide::response, CaptureOutcome::failed);
  }

private:
  using Half = typename CaptureProducer<Memory>::Half;

  inline Half &select(CaptureSide side) noexcept {
    return side == CaptureSide::request ? exchange_.request : exchange_.response;
  }

  inline void finish(CaptureSide side, CaptureOutcome outcome) noexcept {
    auto &half = select(side);
    if (half) {
      half->finish(outcome, Clock::now());
      producer_->publish(std::move(half));
    }
  }

  CaptureProducer<Memory> *producer_;
  CaptureStart context_;
  CapturedExchange<Memory> exchange_;
};

template <ConcurrentAllocator Memory>
Http1Capture(Memory &memory, CaptureProducer<Memory> *producer, CaptureStart context) -> Http1Capture<Memory>;

}
}

// Interface: proxy/http1_observer.cppm
export {
namespace telar::runtime {

template <Http1CapturePolicy Capture>
class Http1TransportObserver {
public:
  inline explicit Http1TransportObserver(ProxyCounters &counters, Capture &capture, CaptureSide side) noexcept : counters_(counters), capture_(capture), side_(side) {}

  inline void headStarted() noexcept {}
  inline void head(std::string_view bytes) noexcept { capture_.head(side_, bytes); }
  inline void payload(std::span<const std::uint8_t> bytes) noexcept { capture_.payload(side_, bytes); }

  inline void lineTooLong(Http1Line line) noexcept {
    counters_.record(line == Http1Line::chunk_size ? ProxyCounter::http1_chunk_line_too_long : ProxyCounter::http1_trailer_line_too_long);
  }

private:
  ProxyCounters &counters_;
  Capture &capture_;
  CaptureSide side_;
};

template <Http1CapturePolicy Capture>
Http1TransportObserver(ProxyCounters &counters, Capture &capture, CaptureSide side) -> Http1TransportObserver<Capture>;

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

  inline void include(StreamReadiness readiness) noexcept {
    readable = readable || readiness == StreamReadiness::readable;
    writable = writable || readiness == StreamReadiness::writable;
    completion = completion || readiness == StreamReadiness::completion;
  }

  auto operator==(const SocketInterest &) const noexcept -> bool = default;

  [[nodiscard]] inline auto satisfies(StreamReadiness readiness) const noexcept -> bool {
    return (readiness == StreamReadiness::readable && readable) || (readiness == StreamReadiness::writable && writable) || (readiness == StreamReadiness::completion && completion);
  }
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

template <Http1CapturePolicy Capture = IgnoreHttp1Capture, typename Relay = Http1MessageRelay>
class Http1Connection {
public:
  inline explicit Http1Connection(ProxyCounters &counters, Capture capture = {}) noexcept : counters_(counters), capture_(std::move(capture)) {
    capture_.begin();
  }

  template <Allocator Memory, typename Context>
  inline Http1Connection(Memory &memory, ProxyCounters &counters, Capture capture, Context context) : counters_(counters), capture_(std::move(capture)), request_(memory, context, false), response_(memory, context, true) {
    capture_.begin();
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  inline bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.http1Exchange");
    if (!rejection_.empty()) {
      return sendRejection(child);
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds && !finished_ && !upgraded_; ++round) {
      bool request_progress = advanceMessage(request_, CaptureSide::request, counters_, capture_, child, origin, readiness);
      active = active || request_progress;
      if (sendContinue(child)) {
        active = true;
        request_progress = advanceMessage(request_, CaptureSide::request, counters_, capture_, child, origin, TunnelReadiness::available()) || request_progress;
      }
      if (request_.state() == State::head_too_large) {
        rejectHead(true);
        return sendRejection(child) || active;
      }
      if (request_.state() == State::failed) {
        if (request_.head()) {
          capture_.fail();
        }
        finished_ = true;
        break;
      }

      if (request_.state() == State::complete) {
        capture_.finishRequest();
      }

      if (!response_started_ && request_.head()) {
        response_.reset(true, request_.head()->head_request);
        if constexpr (requires { response_.destinationHead(request_.originalHead()); }) { response_.destinationHead(request_.originalHead()); }
        response_started_ = true;
      }
      if (!response_started_) {
        break;
      }

      const bool response_progress = advanceMessage(response_, CaptureSide::response, counters_, capture_, origin, child, {readiness.origin, readiness.child});
      active = active || response_progress;
      if (response_.state() == State::head_too_large) {
        capture_.fail();
        rejectHead(false);
        return sendRejection(child) || active;
      }
      if (response_.state() == State::failed) {
        capture_.fail();
        finished_ = true;
        break;
      }
      if (response_.state() == State::complete) {
        finishResponse();
        continue;
      }
      if (!request_progress && !response_progress) {
        break;
      }
    }
    return active;
  }

  inline SocketInterest childInterest() const noexcept {
    if (!rejection_.empty()) {
      SocketInterest interest;
      interest.include(rejection_waiting_);
      return interest;
    }
    SocketInterest interest;
    interest.include(request_.sourceInterest());
    if constexpr (requires { request_.continueBytes(); }) {
      if (!request_.continueBytes().empty()) { interest.include(continue_waiting_); }
    }
    if (response_started_) {
      interest.include(response_.destinationInterest());
    }
    return interest;
  }

  inline SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    if (rejection_.empty()) {
      interest.include(request_.destinationInterest());
      if (response_started_) {
        interest.include(response_.sourceInterest());
      }
    }
    return interest;
  }

  inline bool readsChild() const noexcept {
    return rejection_.empty() && request_.sourceInterest() != StreamReadiness::none;
  }

  inline bool readsOrigin() const noexcept {
    return rejection_.empty() && response_started_ && response_.sourceInterest() != StreamReadiness::none;
  }

  inline bool finished() const noexcept {
    return finished_;
  }

  inline bool upgraded() const noexcept {
    return upgraded_;
  }

  inline bool idle() const noexcept {
    return !finished_ && !upgraded_ && !request_.started();
  }

  inline std::uint32_t inflight() const noexcept {
    return !finished_ && !upgraded_ && request_.started() ? 1 : 0;
  }

  inline auto deadline() const noexcept -> std::optional<std::chrono::steady_clock::time_point> {
    if constexpr (requires { request_.deadline(); }) {
      const auto request = request_.deadline();
      const auto response = response_.deadline();
      return request && response ? std::min(*request, *response) : request ? request : response;
    }
    return std::nullopt;
  }

private:
  using State = Http1MessageRelay::State;

  template <PeekableByteStream Source, ByteStream Destination>
  inline static bool advanceMessage(Relay &message, CaptureSide side, ProxyCounters &counters, Capture &capture, Source &source, Destination &destination, TunnelReadiness readiness) noexcept {
    bool expired = false;
    if constexpr (requires { message.deadline(); }) {
      const auto deadline = message.deadline();
      expired = deadline && std::chrono::steady_clock::now() >= *deadline;
    }
    if (!expired && !readiness.child.satisfies(message.sourceInterest()) && !readiness.origin.satisfies(message.destinationInterest())) {
      return false;
    }
    Http1TransportObserver observer{counters, capture, side};
    return message.advance(source, destination, observer);
  }

  template <ByteStream Child>
  inline bool sendContinue(Child &child) noexcept {
    if (request_.state() == State::failed) { return false; }
    if constexpr (requires { request_.continueBytes(); }) {
      const auto bytes = request_.continueBytes();
      if (bytes.empty()) { return false; }
      const auto result = child.write({reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()});
      if (result.state == StreamResult::State::blocked) { continue_waiting_ = result.waiting; return false; }
      if (result.state != StreamResult::State::data || result.bytes == 0) { finished_ = true; return false; }
      request_.continueWritten(result.bytes);
      continue_waiting_ = StreamReadiness::writable;
      return true;
    }
    return false;
  }

  inline void finishResponse() noexcept {
    const auto &head = *response_.head();
    if (head.informational) {
      capture_.discardInformational();
      response_.reset(true, request_.head()->head_request);
      return;
    }

    if constexpr (requires { response_.captureIncomplete(); capture_.finishResponse(head.status, false); }) {
      capture_.finishResponse(head.status, !response_.captureIncomplete());
    } else { capture_.finishResponse(head.status); }
    if (request_.state() != State::complete) {
      finished_ = true;
    } else if (head.upgrade) {
      upgraded_ = true;
    } else if (head.closes) {
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
    rejection_ = request ? request_head_too_large : response_head_too_large;
  }

  template <ByteStream Child>
  inline bool sendRejection(Child &child) noexcept {
    const auto remaining = rejection_.substr(rejection_offset_);
    const auto sent = child.write({reinterpret_cast<const std::uint8_t *>(remaining.data()), remaining.size()});
    if (sent.state == StreamResult::State::blocked) {
      rejection_waiting_ = sent.waiting;
      return false;
    }
    if (sent.state != StreamResult::State::data || sent.bytes == 0) {
      finished_ = true;
      return false;
    }
    rejection_offset_ += sent.bytes;
    finished_ = rejection_offset_ == rejection_.size();
    return true;
  }

  static constexpr std::size_t maximum_rounds = 8;
  static constexpr std::string_view request_head_too_large = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  static constexpr std::string_view response_head_too_large = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  ProxyCounters &counters_;
  [[no_unique_address]] Capture capture_;
  Relay request_;
  Relay response_;
  StreamReadiness continue_waiting_ = StreamReadiness::writable;
  tbc::view<std::string_view, tbc::lt::static_storage> rejection_;
  std::size_t rejection_offset_ = 0;
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
  template <EventLoop Poller>
  inline void update(Poller &poller, int descriptor, std::uint64_t token, SocketInterest interest) {
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
  inline void remove(Poller &poller) noexcept {
    if (descriptor_ >= 0) {
      poller.remove(descriptor_);
      descriptor_ = -1;
    }
    interest_ = {};
  }

  inline bool matches(const Event &event) const noexcept {
    return descriptor_ >= 0 && event.descriptor == descriptor_ && event.token == token_;
  }

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

template <ConcurrentAllocator Memory>
struct ConnectionObservation {
  ProxyCounters &counters;
  CaptureProducer<Memory> *captures;
  std::uint64_t identity;
  traffic::FlowControl *flows = nullptr;
};

}
}

// Interface: proxy/duplex_relay.cppm
export {
namespace telar::runtime {

template <std::size_t BufferCapacity = RelayDirection<>::capacity>
class DuplexRelay {
  using Direction = RelayDirection<BufferCapacity>;

public:
  template <ByteStream Child, ByteStream Origin>
  inline bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    const bool outgoing = transfer(outbound_, child, origin, readiness.child, readiness.origin);
    const bool incoming = transfer(inbound_, origin, child, readiness.origin, readiness.child);
    return outgoing || incoming;
  }

  inline bool finished() const noexcept {
    return outbound_.finished() && inbound_.finished();
  }

  inline bool halfClosed() const noexcept {
    return outbound_.finished() || inbound_.finished();
  }

  inline bool readsChild() const noexcept { return outbound_.wantsRead(); }
  inline bool readsOrigin() const noexcept { return inbound_.wantsRead(); }

  inline SocketInterest childInterest() const noexcept {
    SocketInterest interest;
    interest.include(outbound_.sourceInterest());
    interest.include(inbound_.destinationInterest());
    return interest;
  }

  inline SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    interest.include(inbound_.sourceInterest());
    interest.include(outbound_.destinationInterest());
    return interest;
  }

private:
  template <ByteStream Source, ByteStream Destination>
  inline static bool transfer(Direction &direction, Source &source, Destination &destination, SocketInterest source_ready, SocketInterest destination_ready) noexcept {
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

  static constexpr std::size_t maximum_transfer_bytes = 128 * 1024;
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
  inline bool rejected() const noexcept { return rejected_; }
  inline std::string_view failureReason() const noexcept { return failure_; }

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
  tbc::view<std::string_view, tbc::lt::a> failure_;
};

class FlowState;

// A stream of one direction of a flow, whose writes a hook may hold or replace.
template <ByteStream Stream>
class FlowStream {
public:
  inline explicit FlowStream(Stream &stream, FlowState *flow, traffic::Direction direction) noexcept : stream_(stream), flow_(flow), direction_(direction) {}
  inline StreamResult read(std::span<Byte> bytes) noexcept;
  inline StreamResult write(std::span<const Byte> bytes) noexcept;
  inline void halfClose() noexcept { stream_.halfClose(); }
  inline StreamResult peek(std::span<Byte> bytes) noexcept requires PeekableByteStream<Stream>;
  inline StreamView peekView(std::size_t maximum) noexcept requires BufferedByteStream<Stream>;
  inline void consume(std::size_t bytes) noexcept requires BufferedByteStream<Stream> { stream_.consume(bytes); }

private:
  Stream &stream_;
  FlowState *flow_;
  traffic::Direction direction_;
};

// A proxied flow as hooks see it. It owns the identity its events carry, so an event it hands out views
// the flow and nothing that outlives a call is kept elsewhere.
class FlowState {
public:
  FlowState() = default;
  FlowState(const FlowState &) = delete;
  FlowState &operator=(const FlowState &) = delete;

  inline ~FlowState() {
    if (!control_) {
      return;
    }
    auto closed = event(traffic::Direction::outbound);
    closed.reason = outbound_.rejected_ ? outbound_.failure_ : inbound_.rejected_ ? inbound_.failure_ : reason_;
    control_->observeFlow(traffic::Kind::flow_close, closed);
    for (const auto *gate : {&outbound_, &inbound_}) {
      if (gate->ticket_) {
        control_->cancel(gate->ticket_);
      }
    }
  }

  // The control the flow reports to, and the reasons it gives, which are usually literals, are region `a`.
  inline void open(tbc::view<traffic::FlowControl *, tbc::lt::a> control, std::uint64_t id, int child, int origin, std::string_view host) noexcept {
    control_ = control;
    id_ = id;
    endpoint(child, client_);
    endpoint(origin, server_);
    host_.assign(host.substr(0, ProxyHostname::maximum_bytes));
    if (control_) {
      control_->observeFlow(traffic::Kind::flow_open, event(traffic::Direction::outbound));
    }
  }

  inline void visibility(traffic::Visibility value) noexcept { visibility_ = value; }
  inline void reason(tbc::view<std::string_view, tbc::lt::a> value) noexcept { reason_ = value; }

  // The flow's identity, which views the flow.
  inline traffic::FlowEvent context() const noexcept { return event(traffic::Direction::outbound); }

  inline void error(tbc::view<std::string_view, tbc::lt::a> value) noexcept {
    reason_ = value;
    if (control_) {
      auto failed = event(traffic::Direction::outbound);
      failed.reason = value;
      control_->observeFlow(traffic::Kind::flow_error, failed);
    }
  }

  inline bool rejected() const noexcept { return outbound_.rejected() || inbound_.rejected(); }

  inline std::optional<traffic::FlowControl::Time> deadline() const noexcept {
    std::optional<traffic::FlowControl::Time> earliest;
    for (const auto *gate : {&outbound_, &inbound_}) {
      if (const auto due = gate->ticket_ ? control_->deadline(gate->ticket_) : std::nullopt) {
        earliest = earliest ? std::min(*earliest, *due) : *due;
      }
    }
    return earliest;
  }

  // A direction fails once; the reason is reported as the opposite direction's when it was reading.
  inline void fail(traffic::Direction direction, tbc::view<std::string_view, tbc::lt::a> reason, bool reading = false) noexcept {
    auto &gate = this->gate(direction);
    if (gate.rejected_) {
      return;
    }
    gate.rejected_ = true;
    gate.failure_ = reason;
    if (control_) {
      auto failed = event(reading ? opposite(direction) : direction);
      failed.offset = gate.offset_;
      failed.reason = reason;
      control_->observeFlow(traffic::Kind::flow_error, failed);
    }
  }

  // The caller retains its input until the entire replacement has been sent, including partial TLS writes.
  template <ByteStream Stream>
  inline StreamResult write(traffic::Direction direction, Stream &stream, std::span<const Byte> bytes) noexcept {
    auto &gate = this->gate(direction);
    if (gate.rejected_) {
      return {StreamResult::State::failed};
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
        return {StreamResult::State::blocked, 0, StreamReadiness::completion};
      }
      gate.ticket_ = 0;
      if (decision.verdict == traffic::Verdict::reject) {
        fail(direction, "hook_rejected");
        return {StreamResult::State::failed};
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
      if (result.state == StreamResult::State::failed || result.state == StreamResult::State::ended) { fail(direction, "socket_write_failed"); }
      return result;
    }
    auto written = event(direction);
    written.offset = gate.offset_;
    written.bytes = output.first(result.bytes);
    control_->observeFlow(traffic::Kind::stream_data, written);
    gate.offset_ += result.bytes;
    if (gate.replacing_) {
      gate.sent_ += result.bytes;
      return gate.sent_ == gate.replacement_size_ ? complete(gate) : StreamResult{StreamResult::State::blocked, 0, StreamReadiness::writable};
    }
    gate.offered_ = false;
    return result;
  }

private:
  inline static traffic::Direction opposite(traffic::Direction direction) noexcept {
    return direction == traffic::Direction::outbound ? traffic::Direction::inbound : traffic::Direction::outbound;
  }

  inline FlowGate &gate(traffic::Direction direction) noexcept {
    return direction == traffic::Direction::outbound ? outbound_ : inbound_;
  }

  inline traffic::FlowEvent event(traffic::Direction direction) const noexcept {
    return {.id = id_, .direction = direction, .visibility = visibility_, .client = client_.view(), .server = server_.view(), .host = host_.view()};
  }

  inline static StreamResult complete(FlowGate &gate) noexcept {
    const auto count = gate.original_size_;
    eraseSensitive(gate.replacement_.bytes().data(), gate.replacement_size_);
    gate.offered_ = gate.replacing_ = false;
    gate.sent_ = gate.replacement_size_ = 0;
    return {StreamResult::State::data, count};
  }

  inline static void endpoint(int socket, FixedText<128> &result) noexcept {
    sockaddr_storage address{};
    socklen_t size = sizeof(address);
    std::array<char, NI_MAXHOST> host{};
    std::array<char, NI_MAXSERV> port{};
    if (::getpeername(socket, reinterpret_cast<sockaddr *>(&address), &size) == 0 && ::getnameinfo(reinterpret_cast<sockaddr *>(&address), size, host.data(), host.size(), port.data(), port.size(), NI_NUMERICHOST | NI_NUMERICSERV) == 0) {
      std::array<char, 128> text{};
      std::snprintf(text.data(), text.size(), address.ss_family == AF_INET6 ? "[%s]:%s" : "%s:%s", host.data(), port.data());
      result.assign(text.data());
    }
  }

  tbc::view<traffic::FlowControl *, tbc::lt::a> control_ = nullptr;
  std::uint64_t id_ = 0;
  traffic::Visibility visibility_ = traffic::Visibility::wire;
  FixedText<128> client_;
  FixedText<128> server_;
  FixedText<ProxyHostname::maximum_bytes> host_;
  tbc::view<std::string_view, tbc::lt::a> reason_ = "closed";
  tbc::view<FlowGate, tbc::lt::a> outbound_;
  tbc::view<FlowGate, tbc::lt::a> inbound_;
};

template <ByteStream Stream>
inline StreamResult FlowStream<Stream>::read(std::span<Byte> bytes) noexcept {
  const auto result = stream_.read(bytes);
  if (flow_ && result.state == StreamResult::State::failed) { flow_->fail(direction_, "socket_read_failed", true); }
  return result;
}

template <ByteStream Stream>
inline StreamResult FlowStream<Stream>::write(std::span<const Byte> bytes) noexcept {
  return flow_ ? flow_->write(direction_, stream_, bytes) : stream_.write(bytes);
}

template <ByteStream Stream>
inline StreamResult FlowStream<Stream>::peek(std::span<Byte> bytes) noexcept requires PeekableByteStream<Stream> {
  const auto result = stream_.peek(bytes);
  if (flow_ && result.state == StreamResult::State::failed) { flow_->fail(direction_, "socket_read_failed", true); }
  return result;
}

template <ByteStream Stream>
inline StreamView FlowStream<Stream>::peekView(std::size_t maximum) noexcept requires BufferedByteStream<Stream> {
  const auto result = stream_.peekView(maximum);
  if (flow_ && result.state == StreamResult::State::failed) { flow_->fail(direction_, "socket_read_failed", true); }
  return result;
}

}
}

// Interface: proxy/http2_capture.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http2Capture {
public:
  inline explicit Http2Capture(CaptureProducer<Memory> *producer, ProxyCounters &counters, CaptureStart context) noexcept
      : request_(producer, counters, context, CaptureSide::request), response_(producer, counters, context, CaptureSide::response) {}

  inline void observe(Http2Direction direction, const Http2Event &event) noexcept {
    auto &streams = select(direction);
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
      streams.finish(event.stream, event.status >= 400 ? CaptureOutcome::failed : CaptureOutcome::finished);
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

  inline void finish(Http2Direction direction) noexcept { select(direction).finish(); }

private:
  inline Http2CaptureStreams<Memory, Clock> &select(Http2Direction direction) noexcept {
    return direction == Http2Direction::request ? request_ : response_;
  }

  Http2CaptureStreams<Memory, Clock> request_;
  Http2CaptureStreams<Memory, Clock> response_;
};

template <ConcurrentAllocator Memory>
Http2Capture(CaptureProducer<Memory> *producer, ProxyCounters &counters, CaptureStart context) -> Http2Capture<Memory>;

}
}

// Interface: proxy/http2_connection.cppm
export {
namespace telar::runtime {

template <Allocator Memory, Http2CapturePolicy Capture = IgnoreHttp2Capture>
class Http2Connection {
public:
  inline explicit Http2Connection(Memory &memory, ProxyCounters &counters, Capture capture = {}) noexcept
      : counters_(counters), capture_(std::move(capture)), request_(memory, Http2Direction::request), response_(memory, Http2Direction::response) {}

  inline ~Http2Connection() { settle(); }

  template <ByteStream Child, ByteStream Origin>
  inline bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.http2Exchange");
    if (finished()) {
      return false;
    }

    const bool outgoing = transfer(request_, streams_, capture_, child, origin, readiness);
    const bool incoming = transfer(response_, streams_, capture_, origin, child, {readiness.origin, readiness.child});
    if (finished()) {
      origin.halfClose();
      settle();
    }
    return outgoing || incoming;
  }

  inline bool finished() const noexcept { return response_.relay.finished(); }
  inline bool halfClosed() const noexcept { return request_.relay.finished() || response_.relay.finished(); }
  inline bool readsChild() const noexcept { return !finished() && request_.relay.wantsRead(); }
  inline bool readsOrigin() const noexcept { return response_.relay.wantsRead(); }
  inline std::uint32_t inflight() const noexcept { return streams_.size(); }

  inline SocketInterest childInterest() const noexcept {
    SocketInterest interest;
    interest.include(request_.relay.sourceInterest());
    interest.include(response_.relay.destinationInterest());
    return interest;
  }

  inline SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    interest.include(response_.relay.sourceInterest());
    interest.include(request_.relay.destinationInterest());
    return interest;
  }

private:
  using Streams = Http2StreamIds<2 * Http2StreamTracker::capacity>;

  inline void observe(Http2Direction direction, const Http2Event &event) noexcept {
    observe(streams_, capture_, direction, event);
  }

  inline static void observe(Streams &streams, Capture &capture, Http2Direction direction, const Http2Event &event) noexcept {
    if (event.kind == Http2Event::Kind::request_started) {
      streams.start(event.stream);
    } else if (event.kind == Http2Event::Kind::response_ended || event.kind == Http2Event::Kind::stream_reset) {
      streams.finish(event.stream);
    }
    capture.observe(direction, event);
  }

  // Where a direction's events go: the tracked streams and the capture, lent while it transfers.
  struct DirectionSink {
    Streams &streams;
    Capture &capture;
    Http2Direction direction;

    inline void emit(const Http2Event &event) noexcept { observe(streams, capture, direction, event); }
  };

  struct Direction {
    inline explicit Direction(Memory &memory, Http2Direction value) noexcept : observer(memory, value), kind(value) {}

    Http2DirectionObserver<Memory> observer;
    Http2Direction kind;
    RelayDirection<> relay;
  };

  template <ByteStream Source, ByteStream Destination>
  inline static bool transfer(Direction &direction, Streams &streams, Capture &capture, Source &source, Destination &destination, TunnelReadiness readiness) noexcept {
    if (!readiness.child.satisfies(direction.relay.sourceInterest()) && !readiness.origin.satisfies(direction.relay.destinationInterest())) {
      return false;
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds; ++round) {
      const auto progress = direction.relay.advance(source, destination, [&](RelayDirection<>::Observation stage, std::span<const std::uint8_t> bytes) noexcept {
        const bool request = direction.kind == Http2Direction::request;
        if ((request && stage == RelayDirection<>::Observation::received) || (!request && stage == RelayDirection<>::Observation::forwarded)) {
          DirectionSink sink{streams, capture, direction.kind};
          direction.observer.observe(bytes, sink);
        }
      });
      active = active || progress.active();
      if (direction.relay.wantsWrite() || progress.read < RelayDirection<>::capacity) {
        break;
      }
    }
    if (direction.relay.finished()) {
      capture.finish(direction.kind);
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

  inline void record(const typename Http2Observer<Memory>::Statistics &statistics) noexcept {
    if (statistics.decode_failed) {
      counters_.record(ProxyCounter::h2_decode_failure);
    }
    if (statistics.header_block_too_large) {
      counters_.record(ProxyCounter::h2_header_block_too_large);
    }
    counters_.record(ProxyCounter::h2_stream_untracked, statistics.untracked_streams);
  }

  static constexpr std::size_t maximum_rounds = 8;
  ProxyCounters &counters_;
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

template <ConcurrentAllocator Memory, Http2CapturePolicy Capture = IgnoreHttp2Capture>
class Http2EndpointConnection {
  static constexpr std::size_t maximum_streams = 64;
  static constexpr std::size_t connection_bytes = 16 * 1024 * 1024;
  static constexpr std::size_t wire_body_bytes = HttpMessageLimits::body_bytes + HttpMessageLimits::head_bytes;
  static constexpr auto collection_timeout = std::chrono::seconds{30};
  using Local = SynchronizedAllocator<BudgetAllocator<Memory>>;
  using Secure = ErasingAllocator<Local>;
  using Time = traffic::FlowControl::Time;
  struct Stream;
  struct Endpoint;

  struct Half {
    inline Half(Local &memory, Stream &stream, bool response) : secure(memory), message(memory, response), queue(secure, wire_body_bytes), stream(stream) { message.version = HttpVersion::http2; }
    Secure secure;
    HttpMessage<Local> message;
    ByteQueue<Secure> queue;
    Stream &stream;
    std::optional<SensitiveAllocation<Local>> decision;
    traffic::HttpPolicy policy;
    Time collect_until{};
    std::uint64_t ticket = 0;
    std::size_t header_bytes = 0, uncredited = 0;
    bool headers_complete = false, trailer_block = false, ended = false, forwarded = false, streaming = false, discard_body = false;
    unsigned informational = 0;
  };

  struct Stream {
    inline Stream(Local &memory, std::int32_t id) : child_id(id), request(memory, *this, false), response(memory, *this, true) {
      request.message.stream = response.message.stream = static_cast<std::uint32_t>(id);
    }
    std::int32_t child_id, origin_id = 0;
    Half request, response;
    bool child_closed = false, origin_closed = false, rejected = false, original_head = false, origin_canceled_for_head = false;
  };

  struct Endpoint {
    inline Endpoint(Local &memory, Http2EndpointConnection &owner, bool child) : memory(memory), owner(owner), child(child) {
      nghttp2_session_callbacks *raw_callbacks = nullptr;
      if (nghttp2_session_callbacks_new(&raw_callbacks) != 0) { throw std::bad_alloc{}; }
      const auto callbacks = std::unique_ptr<nghttp2_session_callbacks, decltype(&nghttp2_session_callbacks_del)>{raw_callbacks, &nghttp2_session_callbacks_del};
      nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks.get(), &beginHeaders);
      nghttp2_session_callbacks_set_on_header_callback(callbacks.get(), &header);
      nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks.get(), &data);
      nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks.get(), &frame);
      nghttp2_session_callbacks_set_on_stream_close_callback(callbacks.get(), &closed);
      nghttp2_session_callbacks_set_on_frame_not_send_callback(callbacks.get(), &notSent);
      nghttp2_option *raw_options = nullptr;
      if (nghttp2_option_new(&raw_options) != 0) { throw std::bad_alloc{}; }
      const auto options = std::unique_ptr<nghttp2_option, decltype(&nghttp2_option_del)>{raw_options, &nghttp2_option_del};
      nghttp2_option_set_no_auto_window_update(options.get(), 1);
      nghttp2_option_set_max_outbound_ack(options.get(), maximum_streams);
      const auto result = child ? nghttp2_session_server_new3(&session, callbacks.get(), this, options.get(), this->memory.callbacks()) : nghttp2_session_client_new3(&session, callbacks.get(), this, options.get(), this->memory.callbacks());
      if (result != 0) { throw std::bad_alloc{}; }
      const std::array<nghttp2_settings_entry, 4> settings{{{NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, maximum_streams}, {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, wire_body_bytes}, {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, HttpMessageLimits::head_bytes}, {NGHTTP2_SETTINGS_ENABLE_PUSH, 0}}};
      if (nghttp2_submit_settings(session, NGHTTP2_FLAG_NONE, settings.data(), child ? settings.size() - 1 : settings.size()) != 0) { close(); throw std::bad_alloc{}; }
    }
    inline ~Endpoint() { close(); }
    inline void close() noexcept { if (session) { nghttp2_session_del(session); session = nullptr; } }
    inline auto stream(std::int32_t id) const noexcept -> Stream * { return static_cast<Stream *>(nghttp2_session_get_stream_user_data(session, id)); }
    inline auto half(tbc::view<Stream &, tbc::lt::a> stream) const noexcept -> tbc::view<Half &, tbc::lt::a> { return child ? stream.request : stream.response; }

    inline static int beginHeaders(nghttp2_session *, const nghttp2_frame *frame, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      try { return endpoint.owner.beginHeaders(endpoint, *frame); }
      catch (...) { return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    }
    // These signatures are fixed by nghttp2's C callback ABI.
    inline static int header(nghttp2_session *, const nghttp2_frame *frame, const std::uint8_t *name, std::size_t name_size, const std::uint8_t *value, std::size_t value_size, std::uint8_t, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      auto *stream = endpoint.stream(frame->hd.stream_id);
      if (!stream || stream->rejected) { return 0; }
      try { endpoint.owner.header(endpoint, *stream, {reinterpret_cast<const char *>(name), name_size}, {reinterpret_cast<const char *>(value), value_size}); return 0; }
      catch (...) { endpoint.owner.reject(*stream, "http2_invalid_headers"); return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    }
    inline static int data(nghttp2_session *, std::uint8_t flags, std::int32_t id, const std::uint8_t *data, std::size_t size, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      if (nghttp2_session_consume_connection(endpoint.session, size) != 0) { return NGHTTP2_ERR_CALLBACK_FAILURE; }
      auto *stream = endpoint.stream(id);
      if (!stream || stream->rejected) { return 0; }
      try { endpoint.owner.data(endpoint, *stream, {data, size}, (flags & NGHTTP2_FLAG_END_STREAM) != 0); }
      catch (...) { endpoint.owner.reject(*stream, "http2_buffer_limit"); }
      return 0;
    }
    inline static int frame(nghttp2_session *, const nghttp2_frame *frame, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      try { endpoint.owner.frame(endpoint, *frame); return 0; }
      catch (...) {
        if (auto *stream = endpoint.stream(frame->hd.stream_id)) { endpoint.owner.reject(*stream, "http2_message_failed"); return 0; }
        return NGHTTP2_ERR_CALLBACK_FAILURE;
      }
    }
    inline static int closed(nghttp2_session *, std::int32_t id, std::uint32_t error, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      if (auto *stream = endpoint.stream(id)) {
        (endpoint.child ? stream->child_closed : stream->origin_closed) = true;
        if (endpoint.child && error == NGHTTP2_NO_ERROR && stream->response.discard_body && stream->response.streaming && stream->origin_id && !stream->origin_closed && !stream->rejected) {
          stream->origin_canceled_for_head = true;
          nghttp2_submit_rst_stream(endpoint.owner.origin_.session, 0, stream->origin_id, NGHTTP2_CANCEL);
        }
        if (error != NGHTTP2_NO_ERROR && !endpoint.owner.closing_) {
          if (!endpoint.child && stream->origin_canceled_for_head) { endpoint.owner.capture_.observe(Http2Direction::response, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream->child_id)}); }
          else { endpoint.owner.reject(*stream, "http2_stream_reset", error); }
        }
      }
      return 0;
    }
    inline static int notSent(nghttp2_session *, const nghttp2_frame *frame, int, void *context) noexcept {
      auto &endpoint = *static_cast<Endpoint *>(context);
      if (frame->hd.type != NGHTTP2_HEADERS) { return 0; }
      for (auto &stream : endpoint.owner.streams_) {
        if (!stream || (endpoint.child ? stream->child_id : stream->origin_id) != frame->hd.stream_id) { continue; }
        (endpoint.child ? stream->child_closed : stream->origin_closed) = true;
        endpoint.owner.reject(*stream, "http2_headers_not_sent");
        break;
      }
      return 0;
    }

    Http2Memory<Local> memory;
    Http2EndpointConnection &owner;
    bool child;
    nghttp2_session *session = nullptr;
    std::optional<SensitiveAllocation<Local>> output;
    std::size_t output_offset = 0;
    StreamReadiness read_wait = StreamReadiness::readable, write_wait = StreamReadiness::writable;
    bool eof = false;
  };

  class Fields {
  public:
    inline explicit Fields(Secure &memory) : names_(AllocatorRef<String<Secure>, Secure>{memory}), fields_(AllocatorRef<nghttp2_nv, Secure>{memory}) { names_.reserve(HttpFields<Local>::maximum_fields + 4); fields_.reserve(HttpFields<Local>::maximum_fields + 4); }
    inline void add(std::string_view name, std::string_view value) {
      names_.emplace_back(name, AllocatorRef<char, Secure>{names_.get_allocator().memory()});
      auto &lower = names_.back();
      std::ranges::transform(lower, lower.begin(), asciiLower);
      fields_.push_back({reinterpret_cast<std::uint8_t *>(lower.data()), reinterpret_cast<std::uint8_t *>(const_cast<char *>(value.data())), lower.size(), value.size(), NGHTTP2_NV_FLAG_NONE});
    }
    inline auto bytes() const noexcept -> std::span<const nghttp2_nv> { return fields_; }
  private:
    Vector<String<Secure>, Secure> names_;
    Vector<nghttp2_nv, Secure> fields_;
  };

public:
  inline explicit Http2EndpointConnection(Memory &memory, Capture capture, traffic::HttpControl *control, traffic::FlowEvent context) : budget_(memory, connection_bytes), memory_(budget_), secure_(memory_), capture_(std::move(capture)), control_(control), context_(context), child_(memory_, *this, true), origin_(memory_, *this, false), streams_(makeSlots(memory_)) {}
  inline ~Http2EndpointConnection() {
    closing_ = true;
    for (auto &stream : streams_) { if (stream) { cancel(stream->request); cancel(stream->response); } }
    child_.close(); origin_.close();
    capture_.finish(Http2Direction::request); capture_.finish(Http2Direction::response);
  }

  template <ByteStream Child, ByteStream Origin>
  inline bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    if (failed_) { return false; }
    bool active = false;
    for (unsigned round = 0; round < maximum_rounds; ++round) {
      bool progress = false;
      progress = send(child_, child, readiness.child) || progress;
      progress = send(origin_, origin, readiness.origin) || progress;
      progress = receive(child_, child, readiness.child) || progress;
      progress = receive(origin_, origin, readiness.origin) || progress;
      for (auto &stream : streams_) {
        if (!stream) { continue; }
        if (!stream->rejected) { resolve(stream->request); resolve(stream->response); }
        if (stream->child_closed && (stream->origin_closed || stream->origin_id == 0)) { stream.reset(); }
      }
      active |= progress;
      if (!progress || failed_) { break; }
    }
    const bool drained_origin = origin_.eof || (!origin_.output && !nghttp2_session_want_write(origin_.session));
    if ((origin_.eof || child_.eof || draining_) && inflight() == 0 && !child_.output && !nghttp2_session_want_write(child_.session) && drained_origin) { failed_ = true; }
    if (failed_) { child.halfClose(); origin.halfClose(); }
    return active;
  }

  inline bool finished() const noexcept { return failed_; }
  inline bool halfClosed() const noexcept { return child_.eof || origin_.eof; }
  inline bool readsChild() const noexcept { return !failed_ && !child_.eof; }
  inline bool readsOrigin() const noexcept { return !failed_ && !origin_.eof; }
  inline std::uint32_t inflight() const noexcept { return static_cast<std::uint32_t>(std::ranges::count_if(streams_, [](const auto &stream) { return bool(stream); })); }
  inline auto childInterest() const noexcept -> SocketInterest { return interest(child_); }
  inline auto originInterest() const noexcept -> SocketInterest { return interest(origin_); }
  inline auto deadline() const noexcept -> std::optional<Time> {
    std::optional<Time> result;
    for (const auto &stream : streams_) {
      if (!stream || stream->rejected) { continue; }
      for (const auto *half : {&stream->request, &stream->response}) {
        const auto next = half->ticket ? control_->httpDeadline(half->ticket) : half->policy.enabled && half->headers_complete && !half->ended && !half->streaming ? std::optional{half->collect_until} : std::nullopt;
        if (next && (!result || *next < *result)) { result = next; }
      }
    }
    return result;
  }

private:
  inline auto source(Half &half) noexcept -> Endpoint & { return half.message.response ? origin_ : child_; }
  inline auto target(Half &half) noexcept -> Endpoint & { return half.message.response ? child_ : origin_; }
  inline auto sourceId(Half &half) const noexcept -> std::int32_t { return half.message.response ? half.stream.origin_id : half.stream.child_id; }
  inline auto targetId(Half &half) const noexcept -> std::int32_t { return half.message.response ? half.stream.child_id : half.stream.origin_id; }
  inline auto context(const Half &half) const noexcept -> traffic::FlowEvent {
    auto event = context_;
    event.direction = half.message.response ? traffic::Direction::inbound : traffic::Direction::outbound;
    return event;
  }

  inline int beginHeaders(Endpoint &endpoint, const nghttp2_frame &frame) {
    if (frame.hd.type != NGHTTP2_HEADERS) { return 0; }
    auto *stream = endpoint.stream(frame.hd.stream_id);
    if (!stream && endpoint.child && frame.headers.cat == NGHTTP2_HCAT_REQUEST && !draining_) {
      for (auto &slot : streams_) {
        if (slot) { continue; }
        slot = makeOwned<Stream>(memory_, memory_, frame.hd.stream_id);
        stream = slot.get();
        if (nghttp2_session_set_stream_user_data(endpoint.session, frame.hd.stream_id, stream) != 0) { throw std::runtime_error{"Set HTTP/2 stream identity"}; }
        break;
      }
    }
    if (!stream || stream->rejected) { return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    auto &half = endpoint.half(*stream);
    half.trailer_block = half.headers_complete;
    if (!half.trailer_block) {
      half.header_bytes = 0;
      half.message.headers.clear();
      half.message.status = 0;
      if (!endpoint.child) { half.message.response_to_head = stream->request.message.method == "HEAD"; }
    }
    return 0;
  }

  inline void header(Endpoint &endpoint, Stream &stream, std::string_view name, std::string_view value) {
    auto &half = endpoint.half(stream);
    if (name.size() + value.size() + 4 > HttpMessageLimits::head_bytes - half.header_bytes) { throw std::length_error{"HTTP/2 header limit"}; }
    half.header_bytes += name.size() + value.size() + 4;
    const auto direction = endpoint.child ? Http2Direction::request : Http2Direction::response;
    capture_.observe(direction, {.kind = endpoint.child ? Http2Event::Kind::request_header : Http2Event::Kind::response_header, .stream = static_cast<std::uint32_t>(stream.child_id), .name = name, .value = value});
    if (half.trailer_block) { half.message.trailers.append(name, value); return; }
    if (name == ":method") { half.message.method.assign(value); }
    else if (name == ":path") { half.message.target.assign(value); }
    else if (name == ":scheme") { half.message.scheme.assign(value); }
    else if (name == ":authority") { half.message.authority.assign(value); }
    else if (name == ":status") {
      unsigned status = 0;
      const auto parsed = std::from_chars(value.data(), value.data() + value.size(), status);
      if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || status < 100 || status > 599) { throw std::invalid_argument{"Invalid HTTP/2 status"}; }
      half.message.status = static_cast<std::uint16_t>(status);
    } else if (name.starts_with(':')) { throw std::invalid_argument{"Unsupported HTTP/2 pseudo field"}; }
    else { half.message.headers.append(name, value); }
  }

  inline void frame(Endpoint &endpoint, const nghttp2_frame &frame) {
    if (frame.hd.type == NGHTTP2_GOAWAY) {
      draining_ = true;
      if (!endpoint.child) {
        for (auto &stream : streams_) {
          if (stream && (stream->origin_id == 0 || stream->origin_id > frame.goaway.last_stream_id)) { reject(*stream, "http2_origin_goaway", NGHTTP2_REFUSED_STREAM); }
        }
      }
      auto &other = endpoint.child ? origin_ : child_;
      check(nghttp2_submit_goaway(other.session, NGHTTP2_FLAG_NONE, endpoint.child ? 0 : highest_forwarded_, frame.goaway.error_code, nullptr, 0));
      return;
    }
    auto *stream = endpoint.stream(frame.hd.stream_id);
    if (!stream || stream->rejected || (frame.hd.type != NGHTTP2_HEADERS && frame.hd.type != NGHTTP2_DATA)) { return; }
    auto &half = endpoint.half(*stream);
    if (frame.hd.type == NGHTTP2_HEADERS && !half.trailer_block) {
      if (!endpoint.child && half.message.status < 200) { informational(half); return; }
      half.headers_complete = true;
      half.collect_until = std::chrono::steady_clock::now() + collection_timeout;
      if (endpoint.child) {
        stream->original_head = half.message.method == "HEAD";
        if (half.message.authority.empty()) { if (const auto host = half.message.headers.get("host")) { half.message.authority.assign(*host); } }
      }
      half.message.validateHttp2();
      half.policy = control_ ? control_->policy(context(half)) : traffic::HttpPolicy{};
      half.streaming = !half.policy.enabled;
      if (half.policy.enabled) {
        if (const auto length = half.message.headers.get("content-length")) {
          std::uint64_t size = 0;
          const auto parsed = std::from_chars(length->data(), length->data() + length->size(), size);
          if (parsed.ec == std::errc{} && size > wire_body_bytes) { unavailable(half, "http2_body_limit"); }
        }
      }
      const bool tunnel = endpoint.child ? half.message.method == "CONNECT" : stream->request.message.method == "CONNECT" && half.message.status >= 200 && half.message.status < 300;
      const auto type = half.message.headers.get("content-type");
      const bool event_stream = type && asciiEqualIgnoreCase(trimText(type->substr(0, type->find(';')), " \t"), "text/event-stream");
      if (half.policy.enabled && (tunnel || event_stream)) { unavailable(half, tunnel ? "http2_tunnel_body" : "http2_streaming_body"); }
      if (half.streaming && !stream->rejected) { forward(half, false); }
      if (endpoint.child && half.policy.enabled && !half.streaming && !stream->rejected) {
        if (const auto expect = half.message.headers.get("expect"); expect && asciiEqualIgnoreCase(*expect, "100-continue") && !(frame.hd.flags & NGHTTP2_FLAG_END_STREAM)) {
          Fields fields{secure_}; fields.add(":status", "100");
          check(nghttp2_submit_headers(child_.session, NGHTTP2_FLAG_NONE, stream->child_id, nullptr, fields.bytes().data(), fields.bytes().size(), nullptr));
          half.message.headers.remove("expect");
        }
      }
    }
    if ((frame.hd.flags & NGHTTP2_FLAG_END_STREAM) && !stream->rejected) {
      half.ended = true;
      capture_.observe(endpoint.child ? Http2Direction::request : Http2Direction::response, {.kind = endpoint.child ? Http2Event::Kind::request_finished : Http2Event::Kind::response_ended, .stream = static_cast<std::uint32_t>(stream->child_id), .status = half.message.status});
      if (half.streaming) { resume(half); }
      else { complete(half); }
    }
  }

  inline void data(Endpoint &endpoint, Stream &stream, std::span<const Byte> bytes, bool end) {
    auto &half = endpoint.half(stream);
    half.uncredited += bytes.size();
    capture_.observe(endpoint.child ? Http2Direction::request : Http2Direction::response, {.kind = endpoint.child ? Http2Event::Kind::request_body : Http2Event::Kind::response_body, .stream = static_cast<std::uint32_t>(stream.child_id), .bytes = bytes});
    if (half.discard_body && half.streaming) { credit(half, bytes.size()); return; }
    if (bytes.size() > wire_body_bytes - half.queue.size()) { unavailable(half, "http2_body_limit"); }
    if (stream.rejected) { return; }
    half.queue.append(bytes);
    if (!half.streaming && half.queue.size() == wire_body_bytes && !end) { unavailable(half, "http2_body_limit"); }
    if (half.streaming) { resume(half); }
  }

  inline void complete(Half &half) {
    try {
      if (!half.message.bodyless()) { half.message.decodeBody(half.queue.readable()); }
      half.decision.emplace(memory_, HttpMessageLimits::message_bytes);
      auto event = context(half);
      event.bytes = HttpMessageCodec::encodeMessage(half.decision->bytes(), half.message);
      half.ticket = control_->interceptHttp(event);
      if (!half.ticket) { forward(half, false); }
    } catch (...) { unavailable(half, "http2_entity_unavailable"); }
  }

  inline void resolve(Half &half) noexcept {
    if (half.ticket) {
      const auto decision = control_->pollHttp(half.ticket, half.decision->bytes());
      if (decision.verdict == traffic::Verdict::pending) { return; }
      half.ticket = 0;
      if (decision.verdict == traffic::Verdict::reject) { reject(half.stream, "http2_interception_rejected"); return; }
      try {
        if (decision.verdict == traffic::Verdict::replace) { HttpMessageCodec::readMessage(half.message, half.decision->bytes().first(decision.bytes)); }
        forward(half, decision.verdict == traffic::Verdict::replace);
      } catch (...) { reject(half.stream, "http2_invalid_decision"); }
    } else if (half.headers_complete && !half.ended && !half.streaming && std::chrono::steady_clock::now() >= half.collect_until) {
      unavailable(half, "http2_collection_timeout");
    }
  }

  inline void unavailable(Half &half, std::string_view reason) noexcept {
    if (half.stream.rejected) { return; }
    if (half.policy.fail_closed) { reject(half.stream, reason); return; }
    auto event = context(half); event.reason = reason;
    if (control_) { control_->httpUnavailable(event); }
    cancel(half);
    half.streaming = true;
    try { if (!half.forwarded) { forward(half, false); } }
    catch (...) { reject(half.stream, "http2_forwarding_failed"); }
  }

  inline void informational(Half &half) {
    if (++half.informational > maximum_informational) { reject(half.stream, "http2_informational_limit"); return; }
    Fields fields{secure_};
    std::array<char, 3> status{};
    std::to_chars(status.data(), status.data() + status.size(), half.message.status);
    fields.add(":status", {status.data(), status.size()});
    for (const auto &field : half.message.headers.fields()) { fields.add(field.name(), field.value()); }
    check(nghttp2_submit_headers(child_.session, NGHTTP2_FLAG_NONE, half.stream.child_id, nullptr, fields.bytes().data(), fields.bytes().size(), nullptr));
  }

  inline void forward(Half &half, bool changed) {
    if (half.forwarded || half.stream.rejected) { return; }
    half.message.validateHttp2();
    const bool source_head = half.message.response_to_head;
    if (half.message.response) {
      changed |= source_head != half.stream.original_head;
      half.message.response_to_head = half.stream.original_head;
      half.discard_body = half.message.bodyless();
    }
    if (changed) {
      half.queue.clear();
      const bool head_representation = half.message.response && half.message.response_to_head && half.message.status >= 200 && half.message.status != 204 && half.message.status != 205 && half.message.status != 304;
      const bool materialized_head = head_representation && (half.message.body_materialized || !half.message.body.empty());
      if (!half.message.bodyless() || materialized_head) { const auto body = half.message.encodeBody(); half.queue.append(body.bytes()); }
      if (!head_representation || materialized_head) { half.message.headers.remove("content-length"); }
      if (!half.message.bodyless() || half.message.status == 205 || materialized_head) {
        std::array<char, 32> length;
        const auto formatted = std::to_chars(length.data(), length.data() + length.size(), half.queue.size());
        half.message.headers.append("content-length", {length.data(), formatted.ptr});
      }
    }
    Fields fields{secure_};
    std::array<char, 3> status{};
    if (half.message.response) {
      std::to_chars(status.data(), status.data() + status.size(), half.message.status);
      fields.add(":status", {status.data(), status.size()});
    } else {
      fields.add(":method", half.message.method);
      if (half.message.method != "CONNECT") { fields.add(":scheme", half.message.scheme); fields.add(":path", half.message.target); }
      fields.add(":authority", half.message.authority);
    }
    for (const auto &field : half.message.headers.fields()) { fields.add(field.name(), field.value()); }
    nghttp2_data_provider2 provider{.source = {.ptr = &half}, .read_callback = &readBody};
    auto &endpoint = target(half);
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
    if (half.discard_body) { half.queue.clear(); credit(half, half.uncredited); }
    if (half.ended && !half.streaming) { credit(half, half.uncredited); }
    half.decision.reset();
  }

  // Returning DEFERRED parks only this data provider; nghttp2 can send every other stream.
  inline static nghttp2_ssize readBody(nghttp2_session *session, std::int32_t id, std::uint8_t *output, std::size_t capacity, std::uint32_t *flags, nghttp2_data_source *source, void *context) noexcept {
    auto &endpoint = *static_cast<Endpoint *>(context);
    auto &half = *static_cast<Half *>(source->ptr);
    if (half.stream.rejected) { return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
    const auto bytes = half.queue.readable().first(std::min(capacity, half.queue.size()));
    if (bytes.empty() && !half.ended) { return NGHTTP2_ERR_DEFERRED; }
    std::ranges::copy(bytes, output);
    half.queue.consume(bytes.size());
    if (half.streaming) { endpoint.owner.credit(half, bytes.size()); }
    if (half.queue.empty() && half.ended) {
      *flags |= NGHTTP2_DATA_FLAG_EOF;
      if (!half.message.trailers.fields().empty()) {
        try {
          Fields fields{endpoint.owner.secure_};
          for (const auto &field : half.message.trailers.fields()) { fields.add(field.name(), field.value()); }
          *flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
          check(nghttp2_submit_trailer(session, id, fields.bytes().data(), fields.bytes().size()));
        } catch (...) { endpoint.owner.reject(half.stream, "http2_trailer_failed"); return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
      }
    }
    return static_cast<nghttp2_ssize>(bytes.size());
  }

  inline void credit(Half &half, std::size_t count) noexcept {
    count = std::min(count, half.uncredited);
    if (count) { nghttp2_session_consume_stream(source(half).session, sourceId(half), count); half.uncredited -= count; }
  }
  inline void resume(Half &half) noexcept {
    if (half.forwarded && !half.stream.rejected) { nghttp2_session_resume_data(target(half).session, targetId(half)); }
  }
  inline void cancel(Half &half) noexcept { if (half.ticket) { control_->cancelHttp(half.ticket); half.ticket = 0; } half.decision.reset(); }
  inline void reject(Stream &stream, std::string_view reason, std::uint32_t code = NGHTTP2_CANCEL) noexcept {
    if (stream.rejected) { return; }
    stream.rejected = true;
    cancel(stream.request); cancel(stream.response);
    if (!stream.child_closed) { nghttp2_submit_rst_stream(child_.session, NGHTTP2_FLAG_NONE, stream.child_id, code); }
    if (stream.origin_id && !stream.origin_closed) { nghttp2_submit_rst_stream(origin_.session, NGHTTP2_FLAG_NONE, stream.origin_id, code); }
    auto event = context_; event.reason = reason;
    if (control_) { control_->httpUnavailable(event); }
    capture_.observe(Http2Direction::request, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream.child_id)});
    capture_.observe(Http2Direction::response, {.kind = Http2Event::Kind::stream_reset, .stream = static_cast<std::uint32_t>(stream.child_id)});
  }

  template <ByteStream Source>
  inline bool receive(Endpoint &endpoint, Source &source, SocketInterest readiness) noexcept {
    if (endpoint.eof || !readiness.satisfies(endpoint.read_wait)) { return false; }
    SensitiveBuffer<io_bytes> input;
    const auto read = source.read(input.bytes());
    if (read.state == StreamResult::State::blocked) { endpoint.read_wait = read.waiting; return false; }
    if (read.state == StreamResult::State::ended || read.state == StreamResult::State::failed) {
      endpoint.eof = true;
      if (!endpoint.child) {
        draining_ = true;
        endpoint.output.reset();
        for (auto &stream : streams_) { if (stream && !stream->origin_closed) { reject(*stream, "http2_origin_closed"); } }
      }
      return true;
    }
    endpoint.read_wait = StreamReadiness::readable;
    const auto consumed = nghttp2_session_mem_recv2(endpoint.session, input.bytes().data(), read.bytes);
    if (consumed < 0 || static_cast<std::size_t>(consumed) != read.bytes) { fail("http2_connection_failed"); }
    return read.bytes != 0;
  }

  template <ByteStream Destination>
  inline bool send(Endpoint &endpoint, Destination &destination, SocketInterest readiness) noexcept {
    if (endpoint.eof && !endpoint.child) { return false; }
    if (!readiness.satisfies(endpoint.write_wait)) { return false; }
    try {
      if (!endpoint.output) {
        const std::uint8_t *bytes = nullptr;
        const auto size = nghttp2_session_mem_send2(endpoint.session, &bytes);
        if (size < 0) { fail("http2_output_failed"); return false; }
        if (size == 0) { return false; }
        endpoint.output.emplace(memory_, static_cast<std::size_t>(size));
        std::copy_n(bytes, size, endpoint.output->bytes().data());
        endpoint.output_offset = 0;
      }
      const auto result = destination.write(endpoint.output->bytes().subspan(endpoint.output_offset));
      if (result.state == StreamResult::State::blocked) { endpoint.write_wait = result.waiting; return false; }
      if (result.state != StreamResult::State::data || result.bytes == 0) { fail("http2_socket_write_failed"); return false; }
      endpoint.write_wait = StreamReadiness::writable;
      endpoint.output_offset += result.bytes;
      if (endpoint.output_offset == endpoint.output->bytes().size()) { endpoint.output.reset(); }
      return true;
    } catch (...) { fail("http2_output_limit"); return false; }
  }

  inline static auto interest(const Endpoint &endpoint) noexcept -> SocketInterest {
    SocketInterest result;
    if (!endpoint.eof) { result.include(endpoint.read_wait); }
    if ((!endpoint.eof || endpoint.child) && (endpoint.output || nghttp2_session_want_write(endpoint.session))) { result.include(endpoint.write_wait); }
    return result;
  }
  inline static void check(int result) { if (result < 0) { throw std::runtime_error{nghttp2_strerror(result)}; } }

  inline void fail(std::string_view reason) noexcept {
    if (failed_) { return; }
    failed_ = true;
    auto event = context_; event.reason = reason;
    if (control_) { control_->httpUnavailable(event); }
  }

  inline static auto makeSlots(Local &memory) {
    return [&]<std::size_t... Index>(std::index_sequence<Index...>) { return std::array<Owned<Stream, Local>, maximum_streams>{((void)Index, Owned<Stream, Local>{nullptr, AllocationDeleter<Stream, Local>{memory}})...}; }(std::make_index_sequence<maximum_streams>{});
  }

  static constexpr unsigned maximum_rounds = 8, maximum_informational = 8;
  static constexpr std::size_t io_bytes = 16 * 1024;
  BudgetAllocator<Memory> budget_;
  Local memory_;
  Secure secure_;
  Capture capture_;
  traffic::HttpControl *control_;
  traffic::FlowEvent context_;
  Endpoint child_, origin_;
  std::array<Owned<Stream, Local>, maximum_streams> streams_;
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

  template <ByteStream Stream>
  inline StreamResult fill(Stream &stream) noexcept {
    const auto result = stream.read(storage_.bytes().subspan(length_));
    if (result.state == StreamResult::State::data) { length_ += result.bytes; }
    return result;
  }
  inline std::span<const std::uint8_t> bytes() noexcept { return storage_.bytes().subspan(offset_, length_ - offset_); }
  inline bool empty() const noexcept { return offset_ == length_; }
  inline void consume(std::size_t count) noexcept { offset_ += count; }

private:
  SensitiveBuffer<capacity> storage_;
  std::size_t offset_ = 0;
  std::size_t length_ = 0;
};

template <PeekableByteStream Stream>
class PrefixedStream {
public:
  inline explicit PrefixedStream(Stream &stream, StreamPrefix &prefix) noexcept : stream_(stream), prefix_(prefix) {}
  inline StreamResult read(std::span<std::uint8_t> bytes) noexcept {
    if (prefix_.empty()) { return stream_.read(bytes); }
    const auto count = std::min(prefix_.bytes().size(), bytes.size());
    std::memcpy(bytes.data(), prefix_.bytes().data(), count);
    prefix_.consume(count);
    return {StreamResult::State::data, count};
  }
  inline StreamResult peek(std::span<std::uint8_t> bytes) noexcept {
    if (prefix_.empty()) { return stream_.peek(bytes); }
    const auto count = std::min(prefix_.bytes().size(), bytes.size());
    std::memcpy(bytes.data(), prefix_.bytes().data(), count);
    return {StreamResult::State::data, count};
  }
  inline StreamResult write(std::span<const std::uint8_t> bytes) noexcept { return stream_.write(bytes); }
  inline void halfClose() noexcept { stream_.halfClose(); }

private:
  Stream &stream_;
  StreamPrefix &prefix_;
};

}
}

// Interface: proxy/application_relay.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ApplicationRelay {
public:
  inline explicit ApplicationRelay(Memory &memory, ConnectionObservation<Memory> observation, std::string_view hostname, FlowState *flow)
      : memory_(memory),
        observation_(observation),
        hostname_(hostname),
        flow_(flow),
        http1_(nullptr, AllocationDeleter<Http1, Memory>{memory}),
        http2_(nullptr, AllocationDeleter<Http2, Memory>{memory}),
        http2_endpoint_(nullptr, AllocationDeleter<Http2Endpoint, Memory>{memory}) {}

  inline void select(HttpProtocol protocol, bool unnegotiated) noexcept {
    if (!selected_) {
      if (!unnegotiated) {
        protocol_ = protocol;
      }
      selected_ = true;
    }
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  inline auto advance(Child &child_stream, Origin &origin_stream, TunnelReadiness readiness) noexcept -> bool {
    bool active = false;

    if (!protocol_) {
      const auto read = prefix_.fill(child_stream);
      active = read.state == StreamResult::State::data;
      identify();
      std::array<Byte, Http2Frame::header_bytes> banner{};
      const auto origin = origin_stream.peek(banner);

      if (!protocol_ && prefix_.empty() && (origin.state == StreamResult::State::data || origin.state == StreamResult::State::ended || origin.state == StreamResult::State::failed)) {
        std::optional<Http2Frame> initial;
        Http2FrameReader reader;

        reader.feed(std::span{banner}.first(origin.bytes), [&](const Http2FrameEvent &event) noexcept -> auto {
          if (event.kind == Http2FrameEvent::Kind::begin) {
            initial = event.frame;
          }
        });

        const bool h2_settings = initial && initial->kind == Http2FrameKind::settings && initial->stream == 0 && initial->flags == 0 && initial->length % Http2Frame::settings_entry_bytes == 0;
        protocol_ = h2_settings ? HttpProtocol::http2 : HttpProtocol::other;
      }

      if (!protocol_) {
        if (!protocol_ && (read.state == StreamResult::State::ended || read.state == StreamResult::State::failed)) {
          protocol_ = HttpProtocol::other;
        }

        if (!protocol_) {
          return active;
        }
      }
    }

    PrefixedStream prefixed{child_stream, prefix_};
    FlowStream child{prefixed, flow_, traffic::Direction::inbound};
    FlowStream origin{origin_stream, flow_, traffic::Direction::outbound};

    if (active) {
      readiness = TunnelReadiness::available();
    }

    return transfer(child, origin, readiness) || active;
  }

  [[nodiscard]] inline auto finished() const noexcept -> bool {
    return failed_ || (http1_ && http1_->finished()) || (http2_ && http2_->finished()) || (http2_endpoint_ && http2_endpoint_->finished()) || duplex_.finished();
  }

  [[nodiscard]] inline auto halfClosed() const noexcept -> bool {
    if (http2_endpoint_) {
      return http2_endpoint_->halfClosed();
    }
    return http2_ ? http2_->halfClosed() : duplex_.halfClosed();
  }

  [[nodiscard]] inline auto idle() const noexcept -> bool {
    return http1_ && http1_->idle();
  }

  [[nodiscard]] inline auto inflight() const noexcept -> std::uint32_t {
    if (http2_endpoint_) {
      return http2_endpoint_->inflight();
    }
    return http2_ ? http2_->inflight() : http1_ ? http1_->inflight()
                                                : 0;
  }

  [[nodiscard]] inline auto buffered() const noexcept -> bool {
    return protocol_ && !prefix_.empty() && readsChild();
  }

  [[nodiscard]] inline auto readsChild() const noexcept -> bool {
    if (http2_endpoint_) {
      return http2_endpoint_->readsChild();
    }
    return http2_ ? http2_->readsChild() : http1_ && !http1_->upgraded() ? http1_->readsChild()
                                                                         : duplex_.readsChild();
  }

  [[nodiscard]] inline auto readsOrigin() const noexcept -> bool {
    if (http2_endpoint_) {
      return http2_endpoint_->readsOrigin();
    }
    return http2_ ? http2_->readsOrigin() : http1_ && !http1_->upgraded() ? http1_->readsOrigin()
                                                                          : duplex_.readsOrigin();
  }

  [[nodiscard]] inline auto deadline() const noexcept -> std::optional<traffic::FlowControl::Time> {
    if (http2_endpoint_) {
      return http2_endpoint_->deadline();
    }
    if (http1_) {
      return http1_->deadline();
    }
    return !protocol_ && sniff_until_ != traffic::FlowControl::Time{} ? std::optional{sniff_until_} : std::nullopt;
  }

  [[nodiscard]] inline auto interest(TlsSide side) const noexcept -> SocketInterest {
    if (!protocol_ && !prefix_.empty()) {
      return {.readable = side == TlsSide::child};
    }
    if (http2_endpoint_) {
      return side == TlsSide::child ? http2_endpoint_->childInterest() : http2_endpoint_->originInterest();
    }
    if (http1_ && !http1_->upgraded()) {
      return side == TlsSide::child ? http1_->childInterest() : http1_->originInterest();
    }

    if (http2_) {
      return side == TlsSide::child ? http2_->childInterest() : http2_->originInterest();
    }

    return side == TlsSide::child ? duplex_.childInterest() : duplex_.originInterest();
  }

private:
  using Http1 = Http1Connection<Http1Capture<Memory>, Http1InterceptedRelay<Memory>>;
  using Http2 = Http2Connection<Memory, Http2Capture<Memory>>;
  using Http2Endpoint = Http2EndpointConnection<Memory, Http2Capture<Memory>>;

  [[nodiscard]] inline auto captureStart(CaptureProtocol protocol) const noexcept -> CaptureStart {
    return {
        .key = {
            observation_.identity,
            0,
        },
        .protocol = protocol,
        .host = hostname_,
    };
  }

  inline void identify() noexcept {
    const auto bytes = prefix_.bytes();
    const std::string_view head{reinterpret_cast<const char *>(bytes.data()), bytes.size()};

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

    const bool h2_prefix = http2.starts_with(head);
    if (!h2_prefix) {
      constexpr std::array methods{"GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE "};
      const bool possible = std::ranges::any_of(methods, [&](std::string_view method) { return method.starts_with(head) || head.starts_with(method); });

      if (!possible) {
        protocol_ = HttpProtocol::other;
        return;
      }

      const auto end = head.find("\r\n");
      if (end != std::string_view::npos) {
        const auto line = head.substr(0, end);
        protocol_ = line.ends_with(" HTTP/1.1") || line.ends_with(" HTTP/1.0") ? HttpProtocol::http11 : HttpProtocol::other;
        return;
      }

      if (std::ranges::any_of(bytes, [](Byte byte) { return byte == 0 || byte >= 127 || (byte < 32 && byte != '\r' && byte != '\n' && byte != '\t'); })) {
        protocol_ = HttpProtocol::other;
        return;
      }
    }

    if (bytes.size() == StreamPrefix::capacity || std::chrono::steady_clock::now() >= sniff_until_) {
      protocol_ = HttpProtocol::other;
    }
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  inline auto transfer(Child &child, Origin &origin, TunnelReadiness readiness) noexcept -> bool {
    if (*protocol_ == HttpProtocol::http2) {
      if (!http2_ && !http2_endpoint_) {
        try {
          Http2Capture capture{observation_.captures, observation_.counters, captureStart(CaptureProtocol::http2)};
          auto *control = observation_.flows ? observation_.flows->http() : nullptr;
          if (control) {
            const auto event = flow_ ? flow_->context() : traffic::FlowEvent{.id = observation_.identity, .host = hostname_};
            http2_endpoint_ = makeOwned<Http2Endpoint>(memory_, memory_, std::move(capture), control, event);
          } else {
            http2_ = makeOwned<Http2>(memory_, memory_, observation_.counters, std::move(capture));
          }
        } catch (...) {
          failed_ = true;
          return false;
        }
      }

      return http2_endpoint_ ? http2_endpoint_->advance(child, origin, readiness) : http2_->advance(child, origin, readiness);
    }

    if (*protocol_ == HttpProtocol::http11) {
      if (!http1_) {
        try {
          Http1Capture capture{memory_, observation_.captures, captureStart(CaptureProtocol::http1)};
          const auto event = flow_ ? flow_->context() : traffic::FlowEvent{.id = observation_.identity, .host = hostname_};
          const HttpRelayContext context{observation_.flows ? observation_.flows->http() : nullptr, event};
          http1_ = makeOwned<Http1>(memory_, memory_, observation_.counters, std::move(capture), context);
        } catch (...) {
          failed_ = true;
          return false;
        }
      }

      if (!http1_->upgraded()) {
        const bool active = http1_->advance(child, origin, readiness);
        if (!http1_->upgraded()) {
          return active;
        }

        return duplex_.advance(child, origin, TunnelReadiness::available()) || active;
      }
    }

    return duplex_.advance(child, origin, readiness);
  }

  Memory &memory_;
  ConnectionObservation<Memory> observation_;
  std::string_view hostname_;
  FlowState *flow_;
  Owned<Http1, Memory> http1_;
  Owned<Http2, Memory> http2_;
  Owned<Http2Endpoint, Memory> http2_endpoint_;
  DuplexRelay<> duplex_;
  StreamPrefix prefix_;
  std::optional<HttpProtocol> protocol_;
  traffic::FlowControl::Time sniff_until_;
  bool selected_ = false;
  bool failed_ = false;
};
}
}

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
  inline tbc::view<std::string_view, tbc::lt::static_storage> recordFailure() noexcept {
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
  inline void reason(tbc::view<std::string_view, tbc::lt::a> value) noexcept { if (flow_) { flow_->reason(value); } }
  inline void error(tbc::view<std::string_view, tbc::lt::a> value) noexcept { if (flow_) { flow_->error(value); } }

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

// Interface: proxy/client_configuration.cppm
export {
namespace telar::runtime {

class ProxyClientConfiguration {
public:
  ProxyClientConfiguration() noexcept = default;

  inline explicit ProxyClientConfiguration(ProxyStatus status, const ProxySecret &secret, std::string_view certificate, std::string_view bundle) noexcept
      : status_(status), secret_(&secret), certificate_(certificate), bundle_(bundle) {}

  inline const ProxyStatus &status() const noexcept {
    return status_;
  }

  template <Allocator Memory>
  inline void apply(Command<Memory> &command) const {
    if (!status_.active) {
      return;
    }

    SensitiveBuffer<256> storage;
    const auto bytes = storage.bytes();
    const auto url = secret_->formatUrl({reinterpret_cast<char *>(bytes.data()), bytes.size()}, *status_.port);
    if (!url) {
      throw SystemError{"Format child proxy URL", EOVERFLOW};
    }
    command.setEnvironment("HTTPS_PROXY", *url);
    command.setEnvironment("https_proxy", *url);
    command.setEnvironment("NODE_USE_ENV_PROXY", "1");
    command.setEnvironment("NODE_EXTRA_CA_CERTS", certificate_);
    for (const auto name : {"SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "AWS_CA_BUNDLE", "GIT_SSL_CAINFO", "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"}) {
      command.setEnvironment(name, bundle_);
    }
    command.setEnvironment("TELAR_PROXY_TLS", "1");
  }

private:
  ProxyStatus status_{};
  const ProxySecret *secret_ = nullptr;
  std::string_view certificate_;
  std::string_view bundle_;
};

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
  inline static ProxyListener bind(std::optional<std::uint16_t> preferred, const ProxyPortRange::Set &reserved) {
    if (preferred) {
      if (auto listener = tryPort(*preferred, true)) {
        return std::move(*listener);
      }
    }

    for (const bool use_reserved : {false, true}) {
      for (std::uint16_t offset = 0; offset < ProxyPortRange::count; ++offset) {
        if (reserved.test(offset) != use_reserved) {
          continue;
        }
        if (auto listener = tryPort(ProxyPortRange::first + offset, false)) {
          return std::move(*listener);
        }
      }
    }
    throw SystemError{"No proxy port available", EADDRINUSE};
  }

  inline FileDescriptor accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (!child) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return child;
      }
      throw SystemError{"Accept proxy connection"};
    }

    configureProxySocket(child.get());
    return child;
  }

  inline int descriptor() const noexcept {
    return socket_.get();
  }

  inline std::uint16_t port() const noexcept {
    return port_;
  }

  inline void close() noexcept {
    socket_.reset();
  }

private:
  inline explicit ProxyListener(FileDescriptor socket, std::uint16_t port) noexcept
      : socket_(std::move(socket)),
        port_(port) {}

  inline static FileDescriptor openSocket() {
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};
    if (!socket) {
      throw SystemError{"Create proxy socket"};
    }
    configureProxySocket(socket.get());
    return socket;
  }

  inline static sockaddr_in address(std::uint16_t port) noexcept {
    sockaddr_in address{};
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return address;
  }

  inline static std::optional<ProxyListener> tryPort(std::uint16_t port, bool reclaim) {
    auto socket = listen(port, false);
    if (!socket && reclaim && !answers(port)) {
      // BSD reuse can shadow a wildcard listener; reclaim only a refused port.
      socket = listen(port, true);
    }
    if (!socket) {
      return std::nullopt;
    }
    return ProxyListener{std::move(socket), port};
  }

  inline static FileDescriptor listen(std::uint16_t port, bool reuse_closed) {
    auto socket = openSocket();
    if (reuse_closed) {
      const int enabled = 1;
      if (::setsockopt(socket.get(), SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Reclaim proxy port"};
      }
    }

    const auto loopback = address(port);
    if (::bind(socket.get(), reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback)) != 0 || ::listen(socket.get(), backlog) != 0) {
      if (errno == EADDRINUSE) {
        return FileDescriptor{};
      }
      throw SystemError{"Bind proxy listener"};
    }
    return socket;
  }

  inline static bool answers(std::uint16_t port) noexcept {
    try {
      auto socket = openSocket();
      const auto loopback = address(port);
      if (::connect(socket.get(), reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback)) == 0) {
        return true;
      }
      if (errno == ECONNREFUSED) {
        return false;
      }
      if (errno != EINPROGRESS) {
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
  inline explicit ProxyPortMemory(Memory &memory, int directory, std::string_view endpoint, bool inherit_legacy)
      : memory_(memory),
        directory_(directory),
        endpoint_(endpoint, AllocatorRef<char, Memory>{memory}) {
    if (endpoint.size() > PATH_MAX || endpoint.contains('\0')) {
      throw SystemError{"Invalid proxy endpoint path", EINVAL};
    }

    identify(endpoint);
    Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
    if (const auto record = recall(name_.data(), bytes)) {
      own_ = record->port;
    }
    if (inherit_legacy) {
      if (const auto record = recall(legacy_name, bytes)) {
        legacy_ = record->port;
      }
    }

    scan([&](const char *name, const Record &record) {
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

  inline std::optional<std::uint16_t> preferred() const noexcept {
    return own_ ? own_ : legacy_;
  }

  inline const ProxyPortRange::Set &reserved() const noexcept {
    return reserved_;
  }

  inline std::string_view filename() const noexcept {
    return {name_.data(), filename_bytes};
  }

  inline bool remember(std::uint16_t port) noexcept {
    if (!ProxyPortRange::contains(port)) {
      return false;
    }

    std::array<char, maximum_record_bytes> record;
    auto *end = std::to_chars(record.data(), record.data() + record.size(), port).ptr;
    *end++ = '\n';
    end = std::copy(endpoint_.begin(), endpoint_.end(), end);
    *end++ = '\n';
    const auto bytes = std::span{reinterpret_cast<const std::uint8_t *>(record.data()), static_cast<std::size_t>(end - record.data())};
    if (writePrivateFile(directory_, filename(), bytes, PrivateFileMode::replace) != 0) {
      return false;
    }

    if (!own_ && legacy_ == port) {
      ::unlinkat(directory_, legacy_name, 0);
    }
    if (reserved_.test(port - ProxyPortRange::first)) {
      scan([&](const char *name, const Record &record) {
        if (record.port == port) {
          ::unlinkat(directory_, name, 0);
        }
      });
    }
    return true;
  }

private:
  struct Record {
    std::uint16_t port;
    std::string_view endpoint;
  };

  struct DirectoryCloser {
    inline void operator()(DIR *directory) const noexcept {
      ::closedir(directory);
    }
  };

  inline void identify(std::string_view endpoint) noexcept {
    Sha256 hash;
    hash.update(endpoint);
    const auto digest = hash.finish();
    auto *end = std::copy(file_prefix.begin(), file_prefix.end(), name_.begin());
    for (std::size_t index = 0; index < digest_bytes; ++index) {
      *end++ = hexadecimal[digest[index] >> 4];
      *end++ = hexadecimal[digest[index] & 15];
    }
    *end = '\0';
  }

  inline tbc::view<std::optional<Record>, tbc::lt::a> recall(std::string_view name, tbc::view<Vector<unsigned char, Memory> &, tbc::lt::a> bytes) const noexcept {
    try {
      if (!readPrivateFile(directory_, name, bytes, maximum_record_bytes)) {
        return std::nullopt;
      }
    } catch (...) {
      return std::nullopt;
    }

    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    const auto newline = text.find('\n');
    auto number = trimCarriageReturns(text.substr(0, newline));
    if (number.starts_with('+')) {
      number.remove_prefix(1);
    }
    if (number.empty() || number.front() == '_' || number.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t port = 0;
    for (const char character : number) {
      if (character == '_') {
        continue;
      }
      if (character < '0' || character > '9') {
        return std::nullopt;
      }
      port = port * 10 + static_cast<unsigned>(character - '0');
      if (port > UINT16_MAX) {
        return std::nullopt;
      }
    }
    if (!ProxyPortRange::contains(static_cast<std::uint16_t>(port))) {
      return std::nullopt;
    }

    const auto tail = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
    return Record{static_cast<std::uint16_t>(port), trimCarriageReturns(tail.substr(0, tail.find('\n')))};
  }

  template <typename Visitor>
  inline void scan(const Visitor &visit) const noexcept {
    try {
      FileDescriptor descriptor{::openat(directory_, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!descriptor) {
        return;
      }
      std::unique_ptr<DIR, DirectoryCloser> directory{::fdopendir(descriptor.get())};
      if (!directory) {
        return;
      }
      descriptor.release();

      Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
      for (std::size_t scanned = 0; scanned < maximum_scanned_entries; ++scanned) {
        const auto *entry = ::readdir(directory.get());
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
    }
  }

  inline static bool isPortFile(std::string_view name) noexcept {
    return name.size() == filename_bytes && name.starts_with(file_prefix) && std::ranges::all_of(name.substr(file_prefix.size()), [](char byte) { return hexadecimal.contains(byte); });
  }

  inline static bool vanished(std::string_view endpoint) noexcept {
    if (!endpoint.starts_with('/') || endpoint.contains('\0')) {
      return false;
    }

    const auto separator = endpoint.rfind('/');
    std::array<char, PATH_MAX + 1> parent;
    const auto length = std::max<std::size_t>(separator, 1);
    if (length >= parent.size()) {
      return false;
    }
    std::copy_n(endpoint.data(), length, parent.data());
    parent[length] = '\0';
    struct stat metadata{};
    return ::stat(parent.data(), &metadata) != 0 && errno == ENOENT;
  }

  inline static std::string_view trimCarriageReturns(std::string_view text) noexcept {
    while (text.ends_with('\r')) {
      text.remove_suffix(1);
    }
    return text;
  }

  static constexpr std::string_view file_prefix = "proxy-port-";
  static constexpr std::string_view hexadecimal = "0123456789abcdef";
  static constexpr char legacy_name[] = "proxy-port";
  static constexpr std::size_t digest_bytes = 8;
  static constexpr std::size_t filename_bytes = file_prefix.size() + digest_bytes * 2;
  static constexpr std::size_t maximum_scanned_entries = 4096;
  static constexpr std::size_t maximum_record_bytes = 8 + PATH_MAX + 1;
  Memory &memory_;
  int directory_;
  String<Memory> endpoint_;
  std::array<char, filename_bytes + 1> name_;
  ProxyPortRange::Set reserved_;
  std::optional<std::uint16_t> own_;
  std::optional<std::uint16_t> legacy_;
};

template <Allocator Memory>
ProxyPortMemory(Memory &memory, int directory, std::string_view endpoint, bool inherit_legacy) -> ProxyPortMemory<Memory>;

}
}

// Interface: proxy/refusal.cppm
export {
namespace telar::runtime {

class ProxyRefusal {
public:
  inline explicit ProxyRefusal(FileDescriptor socket, ProxyConnectionPolicy::Time now) noexcept
      : socket_(std::move(socket)), deadline_(now + drain_duration) {}

  inline bool advance(ProxyConnectionPolicy::Time now) noexcept {
    if (now >= deadline_) {
      return true;
    }
    SocketStream stream{socket_.get()};
    if (offset_ < response.size()) {
      const auto sent = stream.write({reinterpret_cast<const std::uint8_t *>(response.data() + offset_), response.size() - offset_});
      if (sent.state != StreamResult::State::data) {
        return sent.state != StreamResult::State::blocked;
      }
      offset_ += sent.bytes;
      if (offset_ != response.size()) {
        return false;
      }
      stream.halfClose();
    }

    std::array<std::uint8_t, 4096> discarded;
    const auto read = stream.read(discarded);
    return read.state == StreamResult::State::ended || read.state == StreamResult::State::failed;
  }

  inline int descriptor() const noexcept {
    return socket_.get();
  }

  inline SocketInterest interest() const noexcept {
    return {.readable = offset_ == response.size(), .writable = offset_ != response.size()};
  }

  inline ProxyConnectionPolicy::Time deadline() const noexcept {
    return deadline_;
  }

private:
  static constexpr auto drain_duration = std::chrono::milliseconds{20};
  static constexpr std::string_view response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  FileDescriptor socket_;
  ProxyConnectionPolicy::Time deadline_;
  std::size_t offset_ = 0;
};

}
}

// Interface: proxy/service.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, HostnameResolver Resolver>
class ProxyService {
public:
  inline explicit ProxyService(Memory &memory, const ProxyOptions<Memory> &options, const ProxySecret &secret, const TlsInterception<Memory> &interception, ProxyListener listener, traffic::FlowControl *flows = nullptr)
      : memory_(memory), options_(options), secret_(secret), interception_(interception), listener_(std::move(listener)), observations_(memory, options.capture, flows), poller_(memory), resolutions_(resolution_signal_), flows_(flows) {
    poller_.watch(listener_.descriptor(), listener_token);
    poller_.watch(stop_signal_.descriptor(), stop_token);
    poller_.watch(resolution_signal_.descriptor(), resolution_token);
    poller_.watch(adoption_signal_.descriptor(), adoption_token);
    if (flows_) { poller_.watch(flows_->descriptor(), flow_token); }
    worker_ = std::thread{[this] { run(); }};
  }

  inline ~ProxyService() {
    stopping_.store(true, std::memory_order_release);
    stop_signal_.notify();
    worker_.join();
  }

  ProxyService(const ProxyService &) = delete;
  ProxyService &operator=(const ProxyService &) = delete;

  inline std::uint16_t port() const noexcept {
    return listener_.port();
  }

  inline const ProxyCounters &counters() const noexcept {
    return observations_.counters;
  }

  inline CaptureProducer<Memory> &captures() noexcept {
    return observations_.captures;
  }

  inline const CaptureProducer<Memory> &captures() const noexcept {
    return observations_.captures;
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
  using Connection = ProxyConnection<Memory, Resolver>;

  struct Slot {
    inline explicit Slot(Owned<Connection, Memory> connection, std::uint64_t generation) noexcept
        : connection(std::move(connection)), child_generation(generation) {}

    Owned<Connection, Memory> connection;
    SocketWatch child;
    SocketWatch origin;
    std::uint64_t child_generation;
    std::uint64_t origin_generation = 0;
    std::size_t origin_attempt = 0;
  };

  inline void run() noexcept {
    setThreadName("telar.proxy");
    try {
      std::array<Event, Poller::event_capacity> ready{};
      auto reap_at = Policy::Clock::now() + reap_interval;
      while (!stopping_.load(std::memory_order_acquire)) {
        const auto now = Policy::Clock::now();
        auto wake_at = reap_at;
        advanceRefusal(now);
        if (refusal_) {
          wake_at = std::min(wake_at, refusal_->deadline());
        } else if (accept_after_ != Time{}) {
          if (now >= accept_after_) {
            accept_after_ = {};
            poller_.readInterest(listener_.descriptor(), listener_token, true);
          } else {
            wake_at = std::min(wake_at, accept_after_);
          }
        }

        occupied_.forEach([&](std::size_t index) {
          auto &slot = slots_[index];
          if (now >= reap_at) {
            slot->connection->expire(now);
            advance(index, {}, now);
          } else if (slot->connection->buffered() || (slot->connection->deadline() && now >= *slot->connection->deadline())) {
            advance(index, TunnelReadiness::available(), now);
          }
          if (slot) {
            if (const auto deadline = slot->connection->deadline()) {
              wake_at = std::min(wake_at, *deadline);
            }
            if (slot->connection->buffered()) {
              wake_at = now;
            }
          }
        });
        if (now >= reap_at) {
          reap_at = now + reap_interval;
        }

        const auto events = poller_.wait(wake_at - Policy::Clock::now(), ready);
        for (const auto &event : events) {
          if (stopping_.load(std::memory_order_acquire)) {
            break;
          }
          dispatch(event, Policy::Clock::now());
        }
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar proxy service: %s\n", error.what());
      failed_.store(true, std::memory_order_release);
    } catch (...) {
      failed_.store(true, std::memory_order_release);
    }

    refusal_watch_.remove(poller_);
    refusal_.reset();
    occupied_.forEach([this](std::size_t index) { release(index); });
    adoptions_.close();
    poller_.remove(listener_.descriptor());
    listener_.close();
  }

  inline void dispatch(const Event &event, Time now) {
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
      occupied_.forEach([&](std::size_t index) { advance(index, TunnelReadiness::available(), now); });
    } else if (event.token == adoption_token) {
      adoption_signal_.drain();
      while (auto connection = adoptions_.tryReceive()) {
        const auto index = admit(now, true);
        if (!index) {
          continue;
        }
        try {
          keep(makeOwned<Connection>(memory_, memory_, std::move(*connection), options_, secret_, observations_.counters), *index, now);
        } catch (...) {
          release(*index);
        }
      }
    } else if (event.token == refusal_token) {
      if (refusal_watch_.matches(event)) {
        advanceRefusal(now);
      }
    } else {
      const auto index = (event.token >> side_bits) & slot_mask;
      auto &slot = slots_[index];
      if (slot && (slot->child.matches(event) || slot->origin.matches(event))) {
        TunnelReadiness readiness;
        auto &side = slot->origin.matches(event) ? readiness.origin : readiness.child;
        side = {.readable = event.kind == EventKind::readable, .writable = event.kind == EventKind::writable};
        advance(index, readiness, now);
      }
    }
  }

  inline void accept(Time now) {
    TELAR_TRACE("proxy.acceptConnections");
    for (std::size_t accepted = 0; accepted < maximum_accept_batch; ++accepted) {
      FileDescriptor child;
      try {
        child = listener_.accept();
      } catch (const SystemError &error) {
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
        auto connection = makeOwned<Connection>(memory_, memory_, std::move(child), options_, secret_, observations_.counters);
        keep(std::move(connection), *index, now);
      } catch (...) {
        release(*index);
      }
    }
  }

  inline void keep(Owned<Connection, Memory> connection, std::size_t index, Time now) {
    slots_[index].emplace(std::move(connection), nextGeneration());
    occupied_.insert(index);
    active_.fetch_add(1, std::memory_order_relaxed);
    advance(index, {}, now);
  }

  inline std::optional<std::size_t> admit(Time now, bool authenticated = false) noexcept {
    std::size_t unauthenticated = 0;
    occupied_.forEach([&](std::size_t index) { unauthenticated += slots_[index]->connection->policy().phase() == Policy::Phase::connect_head; });
    if (!authenticated && unauthenticated >= Policy::maximum_unauthenticated) {
      if (const auto evicted = oldest(Policy::Closure::evict_head, now)) {
        release(*evicted);
        observations_.counters.record(ProxyCounter::unauthenticated_eviction);
      } else {
        observations_.counters.record(ProxyCounter::unauthenticated_refusal);
        return std::nullopt;
      }
    }

    if (const auto available = occupied_.firstUnused()) {
      return available;
    }
    for (const auto reason : {Policy::Closure::evict_head, Policy::Closure::evict_idle, Policy::Closure::evict_silent}) {
      if (const auto evicted = oldest(reason, now)) {
        release(*evicted);
        observations_.counters.record(ProxyCounter::eviction);
        return evicted;
      }
    }
    limit_drops_.fetch_add(1, std::memory_order_relaxed);
    return std::nullopt;
  }

  inline std::optional<std::size_t> oldest(Policy::Closure reason, Time now) const noexcept {
    std::optional<std::size_t> found;
    auto since = Time::max();
    occupied_.forEach([&](std::size_t index) {
      const auto &policy = slots_[index]->connection->policy();
      const auto started = reason == Policy::Closure::evict_head ? policy.since() : policy.active();
      if (policy.evictable(reason, now) && started < since) {
        since = started;
        found = index;
      }
    });
    return found;
  }

  inline void advance(std::size_t index, TunnelReadiness readiness, Time now) noexcept {
    auto &slot = *slots_[index];
    slot.connection->advance(interception_, observations_, readiness, now);
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
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar proxy watch: %s\n", error.what());
      release(index);
    } catch (...) {
      release(index);
    }
  }

  inline void advanceRefusal(Time now) {
    if (!refusal_) {
      return;
    }
    if (refusal_->advance(now)) {
      refusal_watch_.remove(poller_);
      refusal_.reset();
      poller_.readInterest(listener_.descriptor(), listener_token, true);
    } else {
      refusal_watch_.update(poller_, refusal_->descriptor(), refusal_token, refusal_->interest());
    }
  }

  inline void release(std::size_t index) noexcept {
    auto &slot = slots_[index];
    if (slot) {
      slot->child.remove(poller_);
      slot->origin.remove(poller_);
      slot.reset();
      occupied_.erase(index);
      active_.fetch_sub(1, std::memory_order_relaxed);
    }
  }

  inline static std::uint64_t token(std::size_t index, std::uint64_t generation, TlsSide side) noexcept {
    return (generation << generation_shift) | (index << side_bits) | (side == TlsSide::origin ? 1 : 0);
  }

  inline std::uint64_t nextGeneration() {
    if (generation_ == (UINT64_MAX >> generation_shift)) {
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
  static_assert(Policy::capacity == 1 << slot_bits);

  Memory &memory_;
  const ProxyOptions<Memory> &options_;
  const ProxySecret &secret_;
  const TlsInterception<Memory> &interception_;
  ProxyListener listener_;
  ProxyObservations<Memory> observations_;
  Poller poller_;
  CompletionSignal stop_signal_;
  CompletionSignal resolution_signal_;
  CompletionSignal adoption_signal_;
  DropChannel<redirect::Connection, 32> adoptions_;
  typename NameResolutions<Resolver>::Notifications resolutions_;
  traffic::FlowControl *flows_;
  std::array<std::optional<Slot>, Policy::capacity> slots_;
  SlotIndexes<Policy::capacity> occupied_;
  std::optional<ProxyRefusal> refusal_;
  SocketWatch refusal_watch_;
  Time accept_after_{};
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

template <ConcurrentAllocator Memory, EventLoop Poller, HostnameResolver Resolver, typename Tap = IgnoreCaptureTap>
  requires CaptureTap<Tap, Memory>
class ProxyRuntime {
public:
  inline explicit ProxyRuntime(Memory &memory, const ProxyOptions<Memory> &options, std::string_view endpoint, bool inherit_legacy)
    requires std::same_as<Tap, IgnoreCaptureTap>
      : ProxyRuntime(memory, options, endpoint, inherit_legacy, ignored_tap_) {}

  inline explicit ProxyRuntime(Memory &memory, const ProxyOptions<Memory> &options, std::string_view endpoint, bool inherit_legacy, Tap &tap)
      : memory_(memory), authority_directory_(directoryPath(memory, options)), certificate_path_(AllocatorRef<char, Memory>{memory}), bundle_path_(AllocatorRef<char, Memory>{memory}) {
    TELAR_TRACE("proxy.startRuntime");
    const auto &path = authority_directory_;
    const proxy_trust::Paths trust_paths{memory, path};
    struct stat record_state{};
    const auto record_path = trust_paths.file(proxy_trust::Record::filename);
    const bool has_trust_record = ::lstat(record_path.c_str(), &record_state) == 0;
    if (!options.enabled && !has_trust_record) {
      return;
    }

    library_.emplace(memory);
    const auto destination = trust_paths.nativeDestination(memory, process_environment);
    proxy_trust::SystemCommand trust_command{memory, stderr};
    proxy_trust::Service system_trust{memory, *library_, trust_paths, trust_command, destination};
    if (const auto rotated = system_trust.rotateIfNeeded()) {
      std::fprintf(stderr, "telar proxy trust: installed %.*s\n", static_cast<int>(rotated->fingerprint.size()), rotated->fingerprint.data());
    }

    const bool system_trusted = system_trust.inspect().status == proxy_trust::Status::installed;
    if (!options.enabled) {
      return;
    }

    raiseDescriptorLimit();
    createPrivateDirectory(path);
    FileDescriptor directory{::open(path.c_str(), O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
    if (!directory) {
      throw SystemError{"Open proxy authority directory"};
    }

    const auto authority_kind = system_trusted ? AuthorityKind::system_trust : AuthorityKind::private_local;
    auto authority = std::allocate_shared<CertificateAuthority<Memory>>(AllocatorRef<CertificateAuthority<Memory>, Memory>{memory}, CertificateAuthority<Memory>::loadOrCreate(memory, *library_, directory.get(), authority_kind));
    publishAuthority(*authority, directory.get());
    trust_.emplace(memory, *library_);
    SystemCertificates::read([this](std::span<const std::uint8_t> bytes) { trust_->addDer(bytes); });
    contexts_.emplace(memory, *library_, *trust_);
    interception_.emplace(*contexts_, std::move(authority));
    secret_.emplace(ProxySecretFile::ensure(memory, directory.get()));
    ProxyPortMemory ports{memory, directory.get(), endpoint, inherit_legacy};
    auto listener = ProxyListener::bind(ports.preferred(), ports.reserved());
    ports.remember(listener.port());

    certificate_path_ = path;
    certificate_path_ += '/';
    certificate_path_ += active_certificate;
    bundle_path_ = path;
    bundle_path_ += "/ca-bundle.pem";
    status_.active = true;
    status_.system_trusted = system_trusted;
    status_.port = listener.port();
    status_.preferred_port = ports.preferred();
    status_.scope = std::ranges::any_of(options.intercept_hosts.patterns(), [](const auto &host) { return host.starts_with('*'); }) ? ProxyScope::wildcard : ProxyScope::exact;
    service_.emplace(memory, options, *secret_, *interception_, std::move(listener), flowControl(tap));
    if (options.transparent_redirect) {
      String<Memory> redirect_path{endpoint, AllocatorRef<char, Memory>{memory}};
      redirect_path += redirect::socket_suffix;
      redirect_.emplace(redirect_path, *service_);
    }
    if (options.capture.enabled) {
      captures_.emplace(memory, service_->captures(), options.capture, tap);
    }
  }

  inline ProxyClientConfiguration clientConfiguration() const noexcept {
    return secret_ ? ProxyClientConfiguration{status_, *secret_, certificate_path_, bundle_path_} : ProxyClientConfiguration{};
  }

  inline int descriptor() const noexcept { return captures_ ? captures_->descriptor() : -1; }
  inline bool collect() noexcept { return captures_ && captures_->collect(); }

  inline CaptureMetrics captureMetrics() const noexcept {
    return service_ ? service_->captures().metrics() : CaptureMetrics{};
  }

  inline ProxyMetrics proxyMetrics() const noexcept {
    if (!service_) {
      return {};
    }

    return {service_->counters().snapshot(), service_->active(), service_->limitDrops()};
  }

  inline redirect::MonitorState redirectStatus() const noexcept { return redirect_ ? redirect_->status() : redirect::MonitorState::idle; }
  inline void stopRedirect() noexcept { if (redirect_) { redirect_->stop(); } }

  struct AuthorityStatus {
    bool active = false;
    bool accepting = false;
    proxy_trust::Status trust = proxy_trust::Status::absent;
    std::array<char, 40> fingerprint_sha1{};
    std::array<char, 64> fingerprint_sha256{};
    std::array<Byte, PemDocument::maximum_bytes> certificate{};
    std::size_t certificate_bytes = 0;
  };

  inline AuthorityStatus authorityStatus(bool include_certificate = false) const {
    AuthorityStatus result;
    if (!interception_) { return result; }
    const proxy_trust::Paths paths{memory_, authority_directory_};
    const auto destination = paths.nativeDestination(memory_, process_environment);
    const auto inspection = proxy_trust::inspect(memory_, *library_, paths, destination);
    const auto current = interception_->snapshot();
    requireTls(current != nullptr, "TLS authority is unavailable");
    const auto &authority = *current;
    result.active = true;
    result.accepting = !interception_->suspended();
    result.trust = inspection.status;
    result.fingerprint_sha1 = authority.fingerprint();
    result.fingerprint_sha256 = authority.fingerprintSha256();
    if (inspection.record && inspection.record->fingerprint != result.fingerprint_sha1) { result.trust = proxy_trust::Status::stale; }
    if (include_certificate) {
      const PemDocument certificate{authority.certificate()};
      std::ranges::copy(certificate.bytes(), result.certificate.begin());
      result.certificate_bytes = certificate.bytes().size();
    }
    return result;
  }

  // Keep each handshake's signer alive independently. If store or file updates
  // fail, new TLS sessions remain suspended until an explicit retry synchronizes
  // the signer and the stable trust files used by newly launched processes.
  template <proxy_trust::TrustCommandExecutor Executor>
  inline void manageAuthority(proxy_trust::Action action, Executor &executor) {
    if (!interception_) { throw std::invalid_argument{"Proxy TLS is disabled"}; }
    const proxy_trust::Paths paths{memory_, authority_directory_};
    const auto destination = paths.nativeDestination(memory_, process_environment);
    proxy_trust::Service trust{memory_, *library_, paths, executor, destination};
    const auto previous = trust.inspect();
    if (previous.status == proxy_trust::Status::stale && !previous.record) { throw std::invalid_argument{"Proxy trust record is invalid"}; }
    interception_->suspend(true);
    const auto directory = paths.prepare();
    auto kind = AuthorityKind::private_local;
    if (action == proxy_trust::Action::uninstall) {
      if (previous.record) { trust.uninstall(*previous.record); }
    } else if (action == proxy_trust::Action::install || previous.record) {
      trust.install(previous.record, action == proxy_trust::Action::rotate);
      kind = AuthorityKind::system_trust;
    } else {
      proxy_trust::PreparedAuthority prepared{memory_, *library_, directory.get(), proxy_trust::AuthorityPreparation{.kind = AuthorityKind::private_local, .force_rotation = true}};
      prepared.activate();
      prepared.commit();
    }
    auto authority = std::allocate_shared<CertificateAuthority<Memory>>(AllocatorRef<CertificateAuthority<Memory>, Memory>{memory_}, CertificateAuthority<Memory>::loadOrCreate(memory_, *library_, directory.get(), kind));
    publishAuthority(*authority, directory.get());
    interception_->replace(std::move(authority));
    interception_->suspend(false);
  }

private:
  static constexpr std::string_view active_certificate = "ca-active-cert.pem";

  inline void publishAuthority(const CertificateAuthority<Memory> &authority, int directory) {
    const PemDocument certificate{authority.certificate()};
    if (const auto error = writePrivateFile(directory, active_certificate, certificate.bytes(), PrivateFileMode::replace)) { throw SystemError{"Publish active TLS certificate", error}; }
    authority.writeBundle(directory, SystemRootBundle{memory_}.bytes());
  }

  inline static traffic::FlowControl *flowControl(Tap &tap) noexcept {
    if constexpr (requires { tap.flowControl(); }) {
      return tap.flowControl();
    }
    return nullptr;
  }

  inline static String<Memory> directoryPath(Memory &memory, const ProxyOptions<Memory> &options) {
    if (!options.authority_directory.empty()) {
      return options.authority_directory;
    }

    return proxyAuthorityDirectory(memory, process_environment);
  }

  inline static void raiseDescriptorLimit() noexcept {
    constexpr rlim_t descriptors_per_connection = 2;
    constexpr rlim_t reserved_descriptors = 448;
    constexpr rlim_t wanted = ProxyConnectionPolicy::capacity * descriptors_per_connection + NameResolutions<Resolver>::capacity + reserved_descriptors;
    static_assert(wanted == 1024);
    rlimit limit;
    if (::getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < wanted) {
      limit.rlim_cur = std::min(limit.rlim_max, wanted);
      ::setrlimit(RLIMIT_NOFILE, &limit);
    }
  }

  Memory &memory_;
  String<Memory> authority_directory_;
  String<Memory> certificate_path_;
  String<Memory> bundle_path_;
  ProxyStatus status_{};
  std::optional<TlsLibrary<Memory>> library_;
  std::optional<TlsTrustStore<Memory>> trust_;
  std::optional<TlsContexts<Memory>> contexts_;
  std::optional<TlsInterception<Memory>> interception_;
  std::optional<ProxySecret> secret_;
  std::optional<ProxyService<Memory, Poller, Resolver>> service_;
  std::optional<CapturePipeline<Memory, Tap>> captures_;
  std::optional<redirect::Ingress<ProxyService<Memory, Poller, Resolver>>> redirect_;
  inline static IgnoreCaptureTap ignored_tap_;
};

}
}
