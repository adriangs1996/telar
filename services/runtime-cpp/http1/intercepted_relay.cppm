module;

#include <concepts>
#include <cstdint>
#include <span>
#include <string_view>


#include <algorithm>
#include <cstring>
#include <cstddef>
#include <limits>
#include <optional>
#include <array>


#include "telar_base/memory/allocator.hpp"
#include <utility>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>
#include <memory>
#include <stdexcept>
#include <zstd.h>
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include <charconv>
#include <chrono>

export module telar.runtime.http1.intercepted_relay;

export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.http1.head;

export import telar.base.memory;


export import telar.runtime.http.message;
export import telar.runtime.traffic.control_protocol;

// Interface: http1/observer.cppm
export {
namespace telar::runtime {

enum class Http1Line {
  chunk_size,
  trailer
};

template <typename Observer>
concept Http1Observer = requires(Observer &observer, std::string_view head, std::span<const std::uint8_t> payload, Http1Line line) {
  { observer.headStarted() } noexcept -> std::same_as<void>;
  { observer.head(head) } noexcept -> std::same_as<void>;
  { observer.payload(payload) } noexcept -> std::same_as<void>;
  { observer.lineTooLong(line) } noexcept -> std::same_as<void>;
};

}
}

// Interface: http1/message_relay.cppm
export {
namespace telar::runtime {

class Http1MessageRelay {
public:
  static constexpr std::size_t chunk_line_capacity = 1024;
  static constexpr std::size_t trailer_line_capacity = 8 * 1024;

  enum class State {
    reading_head,
    writing_head,
    reading_body,
    writing_body,
    reading_line,
    writing_line,
    complete,
    failed,
    head_too_large
  };

  inline void reset(bool response, bool response_to_head = false) noexcept {
    response_ = response;
    response_to_head_ = response_to_head;
    state_ = State::reading_head;
    head_.reset();
    reader_.reset();
    read_waiting_ = StreamReadiness::readable;
    write_waiting_ = StreamReadiness::writable;
    write_length_ = 0;
    write_offset_ = 0;
    started_ = false;
  }

  template <PeekableByteStream Source, ByteStream Destination, Http1Observer Observer>
  inline bool advance(Source &source, Destination &destination, Observer &observer) noexcept {
    active_ = false;
    for (std::size_t round = 0; round < maximum_rounds; ++round) {
      bool continued = false;
      switch (state_) {
      case State::reading_head:
        continued = readHead(source, observer);
        break;
      case State::reading_body:
        continued = readBody(source);
        break;
      case State::reading_line:
        continued = readLine(source);
        break;
      case State::writing_head:
      case State::writing_body:
      case State::writing_line: {
        // A borrowed body fragment stays stable through every write retry.
        const bool body_pending = state_ == State::writing_body;
        continued = writePending(destination, observer);
        if constexpr (BufferedByteStream<Source>) {
          if (body_pending && state_ != State::writing_body) {
            source.consume(write_length_);
          }
        }
        break;
      }
      default:
        return active_;
      }
      if (!continued) {
        break;
      }
    }
    return active_;
  }

  inline State state() const noexcept {
    return state_;
  }

  inline const std::optional<Http1Head> &head() const noexcept {
    return head_;
  }

  inline bool started() const noexcept {
    return started_;
  }

  inline StreamReadiness sourceInterest() const noexcept {
    switch (state_) {
    case State::reading_head:
    case State::reading_line:
      return reader_.waiting();
    case State::reading_body:
      return read_waiting_;
    default:
      return StreamReadiness::none;
    }
  }

  inline StreamReadiness destinationInterest() const noexcept {
    return write_offset_ != write_length_ ? write_waiting_ : StreamReadiness::none;
  }

private:
  enum class BodyStage {
    content,
    until_close,
    chunk_size,
    chunk_payload,
    chunk_separator,
    trailer
  };

  template <PeekableByteStream Source, Http1Observer Observer>
  inline bool readHead(Source &source, Observer &observer) noexcept {
    const auto previous = reader_.length();
    const auto result = reader_.receive(source, storage_.bytes(), "\r\n\r\n");
    const bool progress = reader_.length() != previous;
    active_ = active_ || progress;
    if (progress && !started_) {
      started_ = true;
      observer.headStarted();
    }

    switch (result) {
    case DelimitedRead::Result::complete:
      observer.head(text(reader_.length()));
      prepareWrite(State::writing_head, reader_.length());
      return true;
    case DelimitedRead::Result::too_large:
      state_ = State::head_too_large;
      return false;
    case DelimitedRead::Result::ended:
      state_ = State::failed;
      return false;
    case DelimitedRead::Result::pending:
      return progress;
    }
    return false;
  }

  template <ByteStream Source>
  inline bool readBody(Source &source) noexcept {
    const auto capacity = body_stage_ == BodyStage::until_close ? body_capacity : std::min(remaining_, body_capacity);
    const auto received = bodyInput(source, capacity);
    if (received.state == StreamResult::State::blocked) {
      read_waiting_ = received.waiting;
      return false;
    }
    if (received.state != StreamResult::State::data || received.bytes.empty()) {
      state_ = body_stage_ == BodyStage::until_close ? State::complete : State::failed;
      return false;
    }

    active_ = true;
    read_waiting_ = StreamReadiness::readable;
    if (body_stage_ != BodyStage::until_close) {
      remaining_ -= received.bytes.size();
    }
    prepareWrite(State::writing_body, received.bytes.size());
    write_data_ = received.bytes.data();
    return true;
  }

  template <ByteStream Source>
  inline StreamView bodyInput(Source &source, std::size_t maximum) noexcept {
    if constexpr (BufferedByteStream<Source>) {
      return source.peekView(maximum);
    } else {
      const auto received = source.read(storage_.bytes().first(maximum));
      return {received.state, storage_.bytes().first(received.bytes), received.waiting};
    }
  }

  template <PeekableByteStream Source>
  inline bool readLine(Source &source) noexcept {
    const auto previous = reader_.length();
    const auto capacity = body_stage_ == BodyStage::trailer ? trailer_line_capacity : chunk_line_capacity;
    line_result_ = reader_.receive(source, storage_.bytes().first(capacity), "\r\n");
    const bool progress = reader_.length() != previous;
    active_ = active_ || progress;
    if (line_result_ == DelimitedRead::Result::pending) {
      return progress;
    }
    if (reader_.length() == 0) {
      state_ = State::failed;
      return false;
    }
    prepareWrite(State::writing_line, reader_.length());
    return true;
  }

  template <ByteStream Destination, Http1Observer Observer>
  inline bool writePending(Destination &destination, Observer &observer) noexcept {
    const auto sent = destination.write({write_data_ + write_offset_, write_length_ - write_offset_});
    if (sent.state == StreamResult::State::blocked) {
      write_waiting_ = sent.waiting;
      return false;
    }
    if (sent.state != StreamResult::State::data || sent.bytes == 0) {
      if (state_ == State::writing_line) {
        recordLineLimit(observer);
      }
      state_ = State::failed;
      write_offset_ = write_length_;
      return false;
    }

    active_ = true;
    write_waiting_ = StreamReadiness::writable;
    write_offset_ += sent.bytes;
    if (write_offset_ != write_length_) {
      return true;
    }

    switch (state_) {
    case State::writing_head:
      finishHead();
      break;
    case State::writing_body:
      if constexpr (requires { { observer.chunkSeparator(std::span<const std::uint8_t>{}) } noexcept -> std::same_as<void>; }) {
        if (body_stage_ == BodyStage::chunk_separator) { observer.chunkSeparator({write_data_, write_length_}); }
      }
      observer.payload(body_stage_ == BodyStage::chunk_separator ? std::span<const std::uint8_t>{} : std::span{write_data_, write_length_});
      finishBodyBuffer();
      break;
    case State::writing_line:
      recordLineLimit(observer);
      if constexpr (requires { { observer.chunkLine(std::string_view{}) } noexcept -> std::same_as<void>; }) {
        if (body_stage_ == BodyStage::chunk_size && line_result_ == DelimitedRead::Result::complete) { observer.chunkLine(text(write_length_)); }
      }
      if constexpr (requires { { observer.trailer(std::string_view{}) } noexcept -> std::same_as<void>; }) {
        if (body_stage_ == BodyStage::trailer && line_result_ == DelimitedRead::Result::complete && write_length_ > chunk_separator_bytes) {
          observer.trailer(text(write_length_).substr(0, write_length_ - chunk_separator_bytes));
        }
      }
      finishLine();
      break;
    default:
      break;
    }
    return true;
  }

  inline void finishHead() noexcept {
    head_ = Http1Head::analyze(text(write_length_), response_, response_to_head_);
    if (!head_) {
      state_ = State::failed;
      return;
    }

    if (!head_->framing.hasBody()) {
      state_ = State::complete;
      return;
    }
    switch (head_->framing.kind) {
    case Http1Framing::Kind::content_length:
      body_stage_ = BodyStage::content;
      remaining_ = head_->framing.length;
      state_ = State::reading_body;
      break;
    case Http1Framing::Kind::chunked:
      beginLine(BodyStage::chunk_size);
      break;
    case Http1Framing::Kind::until_close:
      body_stage_ = BodyStage::until_close;
      state_ = State::reading_body;
      break;
    default:
      break;
    }
  }

  inline void finishBodyBuffer() noexcept {
    if (body_stage_ == BodyStage::until_close || remaining_ != 0) {
      state_ = State::reading_body;
    } else if (body_stage_ == BodyStage::chunk_payload) {
      remaining_ = chunk_separator_bytes;
      body_stage_ = BodyStage::chunk_separator;
      state_ = State::reading_body;
    } else if (body_stage_ == BodyStage::chunk_separator) {
      beginLine(BodyStage::chunk_size);
    } else {
      state_ = State::complete;
    }
  }

  inline void finishLine() noexcept {
    if (line_result_ != DelimitedRead::Result::complete) {
      state_ = State::failed;
      return;
    }
    if (body_stage_ == BodyStage::trailer) {
      if (text(write_length_) == "\r\n") {
        state_ = State::complete;
      } else {
        beginLine(BodyStage::trailer);
      }
      return;
    }

    const auto line = trimText(text(write_length_), " \t\r\n");
    const auto length = parseHttpNumber<16>(line.substr(0, line.find(';')));
    if (!length) {
      state_ = State::failed;
    } else if (*length == 0) {
      beginLine(BodyStage::trailer);
    } else {
      remaining_ = *length;
      body_stage_ = BodyStage::chunk_payload;
      state_ = State::reading_body;
    }
  }

  template <Http1Observer Observer>
  inline void recordLineLimit(Observer &observer) noexcept {
    if (line_result_ == DelimitedRead::Result::too_large) {
      observer.lineTooLong(body_stage_ == BodyStage::trailer ? Http1Line::trailer : Http1Line::chunk_size);
    }
  }

  inline void prepareWrite(State state, std::size_t length) noexcept {
    state_ = state;
    write_offset_ = 0;
    write_length_ = length;
    write_data_ = storage_.bytes().data();
  }

  inline void beginLine(BodyStage stage) noexcept {
    body_stage_ = stage;
    state_ = State::reading_line;
    reader_.reset();
  }

  inline std::string_view text(std::size_t length) noexcept {
    return {reinterpret_cast<const char *>(storage_.bytes().data()), length};
  }

  static constexpr std::size_t body_capacity = 16 * 1024;
  static constexpr std::size_t chunk_separator_bytes = 2;
  static constexpr std::size_t maximum_rounds = 32;
  SensitiveBuffer<Http1Head::capacity> storage_;
  DelimitedRead reader_;
  std::optional<Http1Head> head_;
  std::size_t remaining_ = 0;
  std::size_t write_length_ = 0;
  std::size_t write_offset_ = 0;
  const std::uint8_t *write_data_ = nullptr;
  StreamReadiness read_waiting_ = StreamReadiness::readable;
  StreamReadiness write_waiting_ = StreamReadiness::writable;
  State state_ = State::reading_head;
  BodyStage body_stage_ = BodyStage::content;
  DelimitedRead::Result line_result_ = DelimitedRead::Result::pending;
  bool response_ = false;
  bool response_to_head_ = false;
  bool started_ = false;
  bool active_ = false;
};

}
}

// Interface: http1/intercepted_relay.cppm
export {
namespace telar::runtime {

struct HttpRelayContext {
  traffic::HttpControl *control = nullptr;
  traffic::FlowEvent event;
};

// The parser retains a blocked fragment while a buffered prefix drains during fail-open fallback.
template <ConcurrentAllocator Memory>
class Http1InterceptedRelay {
  using Secure = ErasingAllocator<Memory>;
  using Bytes = Vector<Byte, Secure>;
  enum class Mode { undecided, buffering, waiting, forwarding, streaming, failed };

  template <Http1Observer Observer>
  struct Observation {
    Http1InterceptedRelay &relay;
    Observer &next;
    inline void headStarted() noexcept { next.headStarted(); }
    inline void head(std::string_view bytes) noexcept { next.head(bytes); relay.readHead(bytes); }
    inline void payload(std::span<const Byte> bytes) noexcept {
      next.payload(bytes);
      if (relay.mode_ != Mode::buffering) { return; }
      try {
        if (bytes.size() > maximum_wire_body - relay.message_.body.size()) { relay.unavailable("http_body_limit"); return; }
        relay.message_.body.insert(relay.message_.body.end(), bytes.begin(), bytes.end());
      } catch (...) { relay.unavailable("http_allocation_failed"); }
    }
    inline void trailer(std::string_view line) noexcept {
      if (relay.mode_ != Mode::buffering) { return; }
      try {
        const auto colon = line.find(':');
        if (colon == std::string_view::npos) { relay.unavailable("http_invalid_trailer"); return; }
        relay.message_.trailers.append(line.substr(0, colon), trimText(line.substr(colon + 1), " \t"));
      } catch (...) { relay.unavailable("http_invalid_trailer"); }
    }
    inline void chunkLine(std::string_view line) noexcept {
      if (relay.mode_ != Mode::buffering) { return; }
      if (!line.ends_with("\r\n")) { relay.unavailable("http_invalid_chunk_size"); return; }
      line.remove_suffix(2);
      if (std::ranges::any_of(line, [](unsigned char byte) { return (byte < 32 && byte != '\t') || byte == 127; })) { relay.unavailable("http_invalid_chunk_size"); return; }
      const auto size = trimText(line.substr(0, line.find(';')), " \t");
      if (size.empty() || !std::ranges::all_of(size, [](unsigned char byte) { return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f'); })) { relay.unavailable("http_invalid_chunk_size"); }
    }
    inline void chunkSeparator(std::span<const Byte> bytes) noexcept {
      if (relay.mode_ != Mode::buffering) { return; }
      for (const auto byte : bytes) {
        if (byte != (relay.separator_lf_ ? '\n' : '\r')) { relay.unavailable("http_invalid_chunk_separator"); return; }
        relay.separator_lf_ = !relay.separator_lf_;
      }
    }
    inline void lineTooLong(Http1Line line) noexcept { next.lineTooLong(line); relay.unavailable("http_line_limit"); }
  };

  template <ByteStream Destination>
  struct Sink {
    Http1InterceptedRelay &relay;
    Destination &destination;
    inline StreamResult read(std::span<Byte>) noexcept { return {StreamResult::State::failed}; }
    inline void halfClose() noexcept {}
    inline StreamResult write(std::span<const Byte> bytes) noexcept {
      if (relay.mode_ == Mode::failed) { return {StreamResult::State::failed}; }
      if (relay.synthetic_) { return {StreamResult::State::blocked, 0, StreamReadiness::completion}; }
      if (relay.mode_ == Mode::streaming) {
        return relay.hasPrefix() ? StreamResult{StreamResult::State::blocked, 0, StreamReadiness::completion} : destination.write(bytes);
      }
      try {
        if (bytes.size() > maximum_wire_body + Http1Head::capacity - relay.wire_.size()) {
          relay.unavailable("http_wire_limit");
          return {relay.mode_ == Mode::failed ? StreamResult::State::failed : StreamResult::State::blocked, 0, StreamReadiness::completion};
        }
        relay.wire_.insert(relay.wire_.end(), bytes.begin(), bytes.end());
        return {StreamResult::State::data, bytes.size()};
      } catch (...) {
        relay.unavailable("http_allocation_failed");
        return {relay.mode_ == Mode::failed ? StreamResult::State::failed : StreamResult::State::blocked, 0, StreamReadiness::completion};
      }
    }
  };

public:
  using State = Http1MessageRelay::State;
  using Time = traffic::FlowControl::Time;

  inline Http1InterceptedRelay(Memory &memory, HttpRelayContext context, bool response) : memory_(memory), secure_(memory), context_(context), message_(memory, response), wire_(AllocatorRef<Byte, Secure>{secure_}) {
    context_.event.direction = response ? traffic::Direction::inbound : traffic::Direction::outbound;
    parser_.reset(response);
  }

  inline ~Http1InterceptedRelay() { cancel(); }

  inline void reset(bool response, bool response_to_head = false) noexcept {
    cancel();
    parser_.reset(response, response_to_head);
    message_.response = response;
    message_.response_to_head = response_to_head;
    wire_.clear();
    decision_.reset();
    forwarded_head_.reset();
    original_head_.reset();
    write_offset_ = head_bytes_ = continue_offset_ = 0;
    mode_ = Mode::undecided;
    continue_ = regenerate_ = false;
    separator_lf_ = false;
    synthetic_ = head_parsed_ = false;
    destination_head_ = response_to_head;
    waiting_ = StreamReadiness::writable;
  }

  template <PeekableByteStream Source, ByteStream Destination, Http1Observer Observer>
  inline bool advance(Source &source, Destination &destination, Observer &observer) noexcept {
    if (mode_ == Mode::failed) { return false; }
    if (mode_ == Mode::buffering && std::chrono::steady_clock::now() >= collect_until_) { unavailable("http_collection_timeout"); }
    bool active = flush(destination);
    if (synthetic_) { return active; }
    if (mode_ == Mode::waiting) { resolve(); active = flush(destination) || active; }
    if (mode_ == Mode::failed || mode_ == Mode::waiting || (hasPrefix() && mode_ != Mode::buffering)) { return active; }

    Sink<Destination> sink{*this, destination};
    Observation<Observer> observation{*this, observer};
    active = parser_.advance(source, sink, observation) || active;
    if (mode_ == Mode::buffering && parser_.state() == State::failed) { unavailable("http_incomplete_message"); }
    if (mode_ == Mode::buffering && parser_.state() == State::complete) { finish(); }
    if (mode_ == Mode::waiting) { resolve(); }
    return flush(destination) || active;
  }

  inline auto state() const noexcept -> State {
    if (mode_ == Mode::failed) { return State::failed; }
    if (synthetic_) { return hasPrefix() ? State::writing_body : State::complete; }
    if (parser_.state() == State::failed && mode_ == Mode::streaming && hasPrefix()) { return State::writing_body; }
    if (parser_.state() == State::complete && (mode_ == Mode::waiting || hasPrefix())) { return State::writing_body; }
    return parser_.state();
  }

  inline auto head() const noexcept -> const std::optional<Http1Head> & {
    return mode_ == Mode::streaming && !hasPrefix() ? parser_.head() : forwarded_head_;
  }

  inline bool started() const noexcept { return parser_.started(); }
  inline bool originalHead() const noexcept { return original_head_.value_or(parser_.head() && parser_.head()->head_request); }
  inline void destinationHead(bool head) noexcept { destination_head_ = head; }
  inline bool captureIncomplete() const noexcept { return synthetic_; }
  inline auto sourceInterest() const noexcept -> StreamReadiness {
    return mode_ == Mode::failed || mode_ == Mode::waiting || (hasPrefix() && mode_ != Mode::buffering) ? StreamReadiness::none : parser_.sourceInterest();
  }
  inline auto destinationInterest() const noexcept -> StreamReadiness {
    if (!continueBytes().empty()) { return StreamReadiness::completion; }
    if (mode_ == Mode::waiting) { return StreamReadiness::completion; }
    if (mode_ == Mode::failed || mode_ == Mode::buffering) { return StreamReadiness::none; }
    return hasPrefix() ? waiting_ : parser_.destinationInterest();
  }
  inline auto deadline() const noexcept -> std::optional<Time> {
    if (ticket_) { return context_.control->httpDeadline(ticket_); }
    return mode_ == Mode::buffering ? std::optional{collect_until_} : std::nullopt;
  }
  inline auto continueBytes() const noexcept -> std::string_view { return continue_ ? continue_response.substr(continue_offset_) : std::string_view{}; }
  inline void continueWritten(std::size_t bytes) noexcept { continue_offset_ += bytes; }

private:
  inline bool hasPrefix() const noexcept { return write_offset_ != wire_.size(); }

  inline void readHead(std::string_view bytes) noexcept {
    policy_ = context_.control ? context_.control->policy(context_.event) : traffic::HttpPolicy{};
    const bool repair = message_.response && message_.response_to_head != destination_head_;
    mode_ = policy_.enabled || repair ? Mode::buffering : Mode::streaming;
    if (mode_ == Mode::streaming) { return; }
    collect_until_ = std::chrono::steady_clock::now() + collection_timeout;
    try {
      const auto parsed = message_.readHttp1Head(bytes, message_.response_to_head);
      head_parsed_ = true;
      if (!message_.response) { original_head_ = parsed.head_request; }
      head_bytes_ = bytes.size();
      if (repair && destination_head_ && !policy_.enabled) { repairHead(); return; }
      if (parsed.framing.kind == Http1Framing::Kind::content_length && parsed.framing.length > maximum_wire_body) { unavailable("http_body_limit"); return; }
      if (const auto type = message_.headers.get("content-type"); type && asciiEqualIgnoreCase(trimText(type->substr(0, type->find(';')), " \t"), "text/event-stream")) { unavailable("http_streaming_body"); return; }
      if (!message_.response) {
        if (const auto expect = message_.headers.get("expect")) {
          if (!asciiEqualIgnoreCase(*expect, "100-continue")) { unavailable("http_unsupported_expectation"); return; }
          continue_ = parsed.framing.hasBody();
          regenerate_ = continue_;
          message_.headers.remove("expect");
        }
      }
    } catch (...) { unavailable("http_invalid_head"); }
  }

  inline void unavailable(std::string_view reason) noexcept {
    if (mode_ == Mode::failed || mode_ == Mode::streaming) { return; }
    auto event = context_.event;
    event.reason = reason;
    if (context_.control) { context_.control->httpUnavailable(event); }
    mode_ = policy_.fail_closed ? Mode::failed : Mode::streaming;
    cancel();
    if (mode_ == Mode::streaming && message_.response && message_.response_to_head != destination_head_) {
      try { if (head_parsed_ && destination_head_) { repairHead(); } else { mode_ = Mode::failed; } }
      catch (...) { mode_ = Mode::failed; }
    }
  }

  inline void finish() noexcept {
    try {
      if (!message_.bodyless()) { message_.decodeBody(message_.body); }
      if (!policy_.enabled) { forward(false); return; }
      decision_.emplace(memory_, HttpMessageLimits::message_bytes);
      auto event = context_.event;
      event.bytes = HttpMessageCodec::encodeMessage(decision_->bytes(), message_);
      ticket_ = context_.control->interceptHttp(event);
      if (ticket_ == 0) { forward(false); }
      else { mode_ = Mode::waiting; }
    } catch (...) { unavailable("http_entity_unavailable"); }
  }

  inline void resolve() noexcept {
    if (!ticket_) { return; }
    const auto decision = context_.control->pollHttp(ticket_, decision_->bytes());
    if (decision.verdict == traffic::Verdict::pending) { return; }
    ticket_ = 0;
    if (decision.verdict == traffic::Verdict::reject) { mode_ = Mode::failed; return; }
    try {
      if (decision.verdict == traffic::Verdict::replace) { HttpMessageCodec::readMessage(message_, decision_->bytes().first(decision.bytes)); }
      forward(decision.verdict == traffic::Verdict::replace);
    } catch (...) {
      auto event = context_.event;
      event.reason = "http_invalid_decision";
      context_.control->httpUnavailable(event);
      mode_ = Mode::failed;
    }
  }

  inline void forward(bool changed) {
    const bool source_head = message_.response_to_head;
    const bool repair = message_.response && source_head != destination_head_;
    if (changed || regenerate_ || repair) {
      if (message_.response) { message_.response_to_head = destination_head_; }
      try {
        auto wire = message_.serializeHttp1();
        wire_.assign(wire.begin(), wire.end());
      } catch (...) { message_.response_to_head = source_head; throw; }
      message_.response_to_head = source_head;
    }
    const std::string_view text{reinterpret_cast<const char *>(wire_.data()), wire_.size()};
    head_bytes_ = text.find("\r\n\r\n") + 4;
    mode_ = Mode::forwarding;
    decision_.reset();
  }

  inline void repairHead() {
    synthetic_ = true;
    message_.headers.set("Connection", "close");
    forward(false);
  }

  template <ByteStream Destination>
  inline bool flush(Destination &destination) noexcept {
    if (!continueBytes().empty()) { return false; }
    if (!hasPrefix() || (mode_ != Mode::forwarding && mode_ != Mode::streaming)) { return false; }
    const auto written = destination.write(std::span{wire_}.subspan(write_offset_));
    if (written.state == StreamResult::State::blocked) { waiting_ = written.waiting; return false; }
    if (written.state != StreamResult::State::data || written.bytes == 0) { mode_ = Mode::failed; return false; }
    write_offset_ += written.bytes;
    waiting_ = StreamReadiness::writable;
    if (!forwarded_head_ && write_offset_ >= head_bytes_) {
      forwarded_head_ = Http1Head::analyze({reinterpret_cast<const char *>(wire_.data()), head_bytes_}, message_.response, message_.response ? destination_head_ : message_.response_to_head);
      if (forwarded_head_ && parser_.head() && parser_.head()->closes) { forwarded_head_->closes = true; }
    }
    if (!hasPrefix()) { wire_.clear(); write_offset_ = 0; }
    return true;
  }

  inline void cancel() noexcept {
    if (ticket_) { context_.control->cancelHttp(ticket_); ticket_ = 0; }
  }

  static constexpr std::size_t maximum_wire_body = HttpMessageLimits::body_bytes + Http1Head::capacity;
  static constexpr auto collection_timeout = std::chrono::seconds{30};
  static constexpr std::string_view continue_response = "HTTP/1.1 100 Continue\r\n\r\n";
  Memory &memory_;
  Secure secure_;
  HttpRelayContext context_;
  HttpMessage<Memory> message_;
  Bytes wire_;
  std::optional<SensitiveAllocation<Memory>> decision_;
  Http1MessageRelay parser_;
  std::optional<Http1Head> forwarded_head_;
  std::optional<bool> original_head_;
  traffic::HttpPolicy policy_;
  Time collect_until_{};
  std::uint64_t ticket_ = 0;
  std::size_t write_offset_ = 0, head_bytes_ = 0, continue_offset_ = 0;
  StreamReadiness waiting_ = StreamReadiness::writable;
  Mode mode_ = Mode::undecided;
  bool continue_ = false, regenerate_ = false;
  bool separator_lf_ = false;
  bool destination_head_ = false, synthetic_ = false, head_parsed_ = false;
};

}
}
