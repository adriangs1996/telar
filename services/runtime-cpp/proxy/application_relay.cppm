module;

#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstddef>
#include <cstdint>
#include <span>
#include <array>
#include <brotli/decode.h>
#include <optional>
#include <utility>
#include <initializer_list>
#include <zlib.h>
#include <string_view>
#include "telar_platform/trace.hpp"
#include <zstd.h>
#include <stdexcept>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <type_traits>
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>


#include <concepts>
#include <cerrno>
#include <exception>
#include <csignal>
#include <sys/socket.h>
#include "telar_platform/file_descriptor.hpp"
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>


#include "telar_base/memory/fixed_text.hpp"
#include <cstdio>
#include <netdb.h>


#include <limits>


#include <nghttp2/nghttp2.h>


#include <brotli/encode.h>
#include <memory>
#include <charconv>


#include <arpa/inet.h>

export module telar.runtime.proxy.application_relay;

export import telar.runtime.exchange_capture.producer;
export import telar.runtime.proxy.http2_capture_streams;
export import telar.runtime.traffic.control_protocol;


export import telar.runtime.proxy.relay_direction;
export import telar.runtime.proxy.http1_capture;


export import telar.runtime.platform.stream_read_buffer;
export import telar.base.memory;


export import telar.runtime.http2.direction_observer;


export import telar.runtime.http.message;


export import telar.runtime.http1.intercepted_relay;
export import telar.runtime.http2.frame_reader;
export import telar.runtime.tls.interception;

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

class FlowGate {
public:
  FlowGate() = default;
  inline ~FlowGate() {
    if (control_ && ticket_) {
      control_->cancel(ticket_);
    }
  }
  FlowGate(const FlowGate &) = delete;
  FlowGate &operator=(const FlowGate &) = delete;

  inline void attach(traffic::FlowControl *control, traffic::FlowEvent event) noexcept {
    control_ = control;
    event_ = event;
  }

  inline void visibility(traffic::Visibility value) noexcept { event_.visibility = value; }
  inline std::optional<traffic::FlowControl::Time> deadline() const noexcept { return ticket_ ? control_->deadline(ticket_) : std::nullopt; }
  inline bool rejected() const noexcept { return rejected_; }
  inline std::string_view failureReason() const noexcept { return failure_; }
  inline void fail(std::string_view reason, bool reading = false) noexcept {
    if (rejected_) { return; }
    rejected_ = true;
    failure_ = reason;
    if (control_) {
      auto event = event_;
      event.bytes = {};
      event.reason = reason;
      if (reading) { event.direction = event.direction == traffic::Direction::outbound ? traffic::Direction::inbound : traffic::Direction::outbound; }
      control_->observeFlow(traffic::Kind::flow_error, event);
    }
  }

  // The caller retains its input until the entire replacement has been sent, including partial TLS writes.
  template <ByteStream Stream>
  inline StreamResult write(Stream &stream, std::span<const Byte> bytes) noexcept {
    if (rejected_) {
      return {StreamResult::State::failed};
    }
    if (!control_) {
      return stream.write(bytes);
    }
    if (!offered_) {
      event_.bytes = bytes.first(std::min(bytes.size(), traffic::FlowControl::chunk_bytes));
      original_size_ = event_.bytes.size();
      ticket_ = control_->intercept(event_);
      offered_ = true;
    }
    if (ticket_) {
      const auto decision = control_->poll(ticket_, replacement_.bytes());
      if (decision.verdict == traffic::Verdict::pending) {
        return {StreamResult::State::blocked, 0, StreamReadiness::completion};
      }
      ticket_ = 0;
      if (decision.verdict == traffic::Verdict::reject) {
        fail("hook_rejected");
        return {StreamResult::State::failed};
      }
      replacing_ = decision.verdict == traffic::Verdict::replace;
      replacement_size_ = decision.bytes;
    }

    const auto input = bytes.first(original_size_);
    const auto output = replacing_ ? replacement_.bytes().first(replacement_size_).subspan(sent_) : input;
    if (output.empty()) {
      return complete();
    }
    const auto result = stream.write(output);
    if (result.state != StreamResult::State::data) {
      if (result.state == StreamResult::State::failed || result.state == StreamResult::State::ended) { fail("socket_write_failed"); }
      return result;
    }
    event_.bytes = output.first(result.bytes);
    control_->observeFlow(traffic::Kind::stream_data, event_);
    event_.offset += result.bytes;
    if (replacing_) {
      sent_ += result.bytes;
      return sent_ == replacement_size_ ? complete() : StreamResult{StreamResult::State::blocked, 0, StreamReadiness::writable};
    }
    offered_ = false;
    return result;
  }

private:
  inline StreamResult complete() noexcept {
    const auto count = original_size_;
    eraseSensitive(replacement_.bytes().data(), replacement_size_);
    offered_ = replacing_ = false;
    sent_ = replacement_size_ = 0;
    return {StreamResult::State::data, count};
  }

  traffic::FlowControl *control_ = nullptr;
  traffic::FlowEvent event_;
  SensitiveBuffer<traffic::FlowControl::chunk_bytes> replacement_;
  std::uint64_t ticket_ = 0;
  std::size_t original_size_ = 0;
  std::size_t replacement_size_ = 0;
  std::size_t sent_ = 0;
  bool offered_ = false;
  bool replacing_ = false;
  bool rejected_ = false;
  std::string_view failure_;
};

template <ByteStream Stream>
class FlowStream {
public:
  inline explicit FlowStream(Stream &stream, FlowGate &gate) noexcept : stream_(stream), gate_(&gate) {}
  inline explicit FlowStream(Stream &stream, FlowGate *gate) noexcept : stream_(stream), gate_(gate) {}
  inline StreamResult read(std::span<Byte> bytes) noexcept {
    const auto result = stream_.read(bytes);
    if (gate_ && result.state == StreamResult::State::failed) { gate_->fail("socket_read_failed", true); }
    return result;
  }
  inline StreamResult write(std::span<const Byte> bytes) noexcept { return gate_ ? gate_->write(stream_, bytes) : stream_.write(bytes); }
  inline void halfClose() noexcept { stream_.halfClose(); }
  inline StreamResult peek(std::span<Byte> bytes) noexcept requires PeekableByteStream<Stream> {
    const auto result = stream_.peek(bytes);
    if (gate_ && result.state == StreamResult::State::failed) { gate_->fail("socket_read_failed", true); }
    return result;
  }
  inline StreamView peekView(std::size_t maximum) noexcept requires BufferedByteStream<Stream> {
    const auto result = stream_.peekView(maximum);
    if (gate_ && result.state == StreamResult::State::failed) { gate_->fail("socket_read_failed", true); }
    return result;
  }
  inline void consume(std::size_t bytes) noexcept requires BufferedByteStream<Stream> { stream_.consume(bytes); }
private:
  Stream &stream_;
  FlowGate *gate_;
};

class FlowState {
public:
  inline ~FlowState() {
    if (control_) {
      event_.reason = outbound.rejected() ? outbound.failureReason() : inbound.rejected() ? inbound.failureReason() : reason_;
      control_->observeFlow(traffic::Kind::flow_close, event_);
    }
  }

  inline void open(traffic::FlowControl *control, std::uint64_t id, int child, int origin, std::string_view host) noexcept {
    control_ = control;
    endpoint(child, client_);
    endpoint(origin, server_);
    event_ = {.id = id, .client = client_.view(), .server = server_.view(), .host = host};
    outbound.attach(control, event_);
    auto incoming = event_;
    incoming.direction = traffic::Direction::inbound;
    inbound.attach(control, incoming);
    if (control_) {
      control_->observeFlow(traffic::Kind::flow_open, event_);
    }
  }

  inline void visibility(traffic::Visibility value) noexcept {
    event_.visibility = value;
    outbound.visibility(value);
    inbound.visibility(value);
  }

  inline void reason(std::string_view value) noexcept { reason_ = value; }
  inline auto context() const noexcept -> traffic::FlowEvent { return event_; }
  inline void error(std::string_view value) noexcept {
    reason_ = value;
    if (control_) {
      event_.reason = value;
      control_->observeFlow(traffic::Kind::flow_error, event_);
    }
  }
  inline bool rejected() const noexcept { return outbound.rejected() || inbound.rejected(); }

  inline std::optional<traffic::FlowControl::Time> deadline() const noexcept {
    const auto out = outbound.deadline();
    const auto in = inbound.deadline();
    return out && in ? std::min(*out, *in) : out ? out : in;
  }

  FlowGate outbound;
  FlowGate inbound;

private:
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
  traffic::FlowControl *control_ = nullptr;
  traffic::FlowEvent event_;
  FixedText<128> client_;
  FixedText<128> server_;
  std::string_view reason_ = "closed";
};

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

    const bool outgoing = transfer(request_, child, origin, readiness);
    const bool incoming = transfer(response_, origin, child, {readiness.origin, readiness.child});
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
  inline void observe(Http2Direction direction, const Http2Event &event) noexcept {
    if (event.kind == Http2Event::Kind::request_started) {
      streams_.start(event.stream);
    } else if (event.kind == Http2Event::Kind::response_ended || event.kind == Http2Event::Kind::stream_reset) {
      streams_.finish(event.stream);
    }
    capture_.observe(direction, event);
  }

  struct DirectionSink {
    Http2Connection &connection;
    Http2Direction direction;

    inline void emit(const Http2Event &event) noexcept { connection.observe(direction, event); }
  };

  struct Direction {
    inline explicit Direction(Memory &memory, Http2Direction value) noexcept : observer(memory, value), kind(value) {}

    Http2DirectionObserver<Memory> observer;
    Http2Direction kind;
    RelayDirection<> relay;
  };

  template <ByteStream Source, ByteStream Destination>
  inline bool transfer(Direction &direction, Source &source, Destination &destination, TunnelReadiness readiness) noexcept {
    if (!readiness.child.satisfies(direction.relay.sourceInterest()) && !readiness.origin.satisfies(direction.relay.destinationInterest())) {
      return false;
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds; ++round) {
      const auto progress = direction.relay.advance(source, destination, [&](RelayDirection<>::Observation stage, std::span<const std::uint8_t> bytes) noexcept {
        const bool request = direction.kind == Http2Direction::request;
        if ((request && stage == RelayDirection<>::Observation::received) || (!request && stage == RelayDirection<>::Observation::forwarded)) {
          DirectionSink sink{*this, direction.kind};
          direction.observer.observe(bytes, sink);
        }
      });
      active = active || progress.active();
      if (direction.relay.wantsWrite() || progress.read < RelayDirection<>::capacity) {
        break;
      }
    }
    if (direction.relay.finished()) {
      capture_.finish(direction.kind);
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
  Http2StreamIds<2 * Http2StreamTracker::capacity> streams_;
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
    inline auto half(Stream &stream) const noexcept -> Half & { return child ? stream.request : stream.response; }

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
    FlowStream child{prefixed, flow_ ? &flow_->inbound : nullptr};
    FlowStream origin{origin_stream, flow_ ? &flow_->outbound : nullptr};

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
