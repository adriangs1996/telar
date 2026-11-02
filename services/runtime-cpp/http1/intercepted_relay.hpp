#pragma once

#include "../http/message.hpp"
#include "../traffic/flow.hpp"
#include "message_relay.hpp"

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
    void headStarted() noexcept { next.headStarted(); }
    void head(std::string_view bytes) noexcept { next.head(bytes); relay.readHead(bytes); }
    void payload(std::span<const Byte> bytes) noexcept {
      next.payload(bytes);
      if (relay.mode_ != Mode::buffering) { return; }
      try {
        if (bytes.size() > maximum_wire_body - relay.message_.body.size()) { relay.unavailable("http_body_limit"); return; }
        relay.message_.body.insert(relay.message_.body.end(), bytes.begin(), bytes.end());
      } catch (...) { relay.unavailable("http_allocation_failed"); }
    }
    void trailer(std::string_view line) noexcept {
      if (relay.mode_ != Mode::buffering) { return; }
      try {
        const auto colon = line.find(':');
        if (colon == std::string_view::npos) { relay.unavailable("http_invalid_trailer"); return; }
        relay.message_.trailers.append(line.substr(0, colon), trimText(line.substr(colon + 1), " \t"));
      } catch (...) { relay.unavailable("http_invalid_trailer"); }
    }
    void chunkLine(std::string_view line) noexcept {
      if (relay.mode_ != Mode::buffering) { return; }
      if (!line.ends_with("\r\n")) { relay.unavailable("http_invalid_chunk_size"); return; }
      line.remove_suffix(2);
      if (std::ranges::any_of(line, [](unsigned char byte) { return (byte < 32 && byte != '\t') || byte == 127; })) { relay.unavailable("http_invalid_chunk_size"); return; }
      const auto size = trimText(line.substr(0, line.find(';')), " \t");
      if (size.empty() || !std::ranges::all_of(size, [](unsigned char byte) { return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f'); })) { relay.unavailable("http_invalid_chunk_size"); }
    }
    void chunkSeparator(std::span<const Byte> bytes) noexcept {
      if (relay.mode_ != Mode::buffering) { return; }
      for (const auto byte : bytes) {
        if (byte != (relay.separator_lf_ ? '\n' : '\r')) { relay.unavailable("http_invalid_chunk_separator"); return; }
        relay.separator_lf_ = !relay.separator_lf_;
      }
    }
    void lineTooLong(Http1Line line) noexcept { next.lineTooLong(line); relay.unavailable("http_line_limit"); }
  };

  template <ByteStream Destination>
  struct Sink {
    Http1InterceptedRelay &relay;
    Destination &destination;
    StreamResult read(std::span<Byte>) noexcept { return {StreamResult::State::failed}; }
    void halfClose() noexcept {}
    StreamResult write(std::span<const Byte> bytes) noexcept {
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

  Http1InterceptedRelay(Memory &memory, HttpRelayContext context, bool response) : memory_(memory), secure_(memory), context_(context), message_(memory, response), wire_(AllocatorRef<Byte, Secure>{secure_}) {
    context_.event.direction = response ? traffic::Direction::inbound : traffic::Direction::outbound;
    parser_.reset(response);
  }

  ~Http1InterceptedRelay() { cancel(); }

  void reset(bool response, bool response_to_head = false) noexcept {
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
  bool advance(Source &source, Destination &destination, Observer &observer) noexcept {
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

  auto state() const noexcept -> State {
    if (mode_ == Mode::failed) { return State::failed; }
    if (synthetic_) { return hasPrefix() ? State::writing_body : State::complete; }
    if (parser_.state() == State::failed && mode_ == Mode::streaming && hasPrefix()) { return State::writing_body; }
    if (parser_.state() == State::complete && (mode_ == Mode::waiting || hasPrefix())) { return State::writing_body; }
    return parser_.state();
  }

  auto head() const noexcept -> const std::optional<Http1Head> & {
    return mode_ == Mode::streaming && !hasPrefix() ? parser_.head() : forwarded_head_;
  }

  bool started() const noexcept { return parser_.started(); }
  bool originalHead() const noexcept { return original_head_.value_or(parser_.head() && parser_.head()->head_request); }
  void destinationHead(bool head) noexcept { destination_head_ = head; }
  bool captureIncomplete() const noexcept { return synthetic_; }
  auto sourceInterest() const noexcept -> StreamReadiness {
    return mode_ == Mode::failed || mode_ == Mode::waiting || (hasPrefix() && mode_ != Mode::buffering) ? StreamReadiness::none : parser_.sourceInterest();
  }
  auto destinationInterest() const noexcept -> StreamReadiness {
    if (!continueBytes().empty()) { return StreamReadiness::completion; }
    if (mode_ == Mode::waiting) { return StreamReadiness::completion; }
    if (mode_ == Mode::failed || mode_ == Mode::buffering) { return StreamReadiness::none; }
    return hasPrefix() ? waiting_ : parser_.destinationInterest();
  }
  auto deadline() const noexcept -> std::optional<Time> {
    if (ticket_) { return context_.control->httpDeadline(ticket_); }
    return mode_ == Mode::buffering ? std::optional{collect_until_} : std::nullopt;
  }
  auto continueBytes() const noexcept -> std::string_view { return continue_ ? continue_response.substr(continue_offset_) : std::string_view{}; }
  void continueWritten(std::size_t bytes) noexcept { continue_offset_ += bytes; }

private:
  bool hasPrefix() const noexcept { return write_offset_ != wire_.size(); }

  void readHead(std::string_view bytes) noexcept {
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

  void unavailable(std::string_view reason) noexcept {
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

  void finish() noexcept {
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

  void resolve() noexcept {
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

  void forward(bool changed) {
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

  void repairHead() {
    synthetic_ = true;
    message_.headers.set("Connection", "close");
    forward(false);
  }

  template <ByteStream Destination>
  bool flush(Destination &destination) noexcept {
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

  void cancel() noexcept {
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
