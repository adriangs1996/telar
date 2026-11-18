module telar.runtime.proxy.intercepted_relay;
import telar.base.ds;

namespace telar::runtime {

  void Http1MessageRelay::reset(bool response, bool response_to_head) noexcept {
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

  auto Http1MessageRelay::state() const noexcept -> State {
    return state_;
  }

  const ds::Option<Http1Head>& Http1MessageRelay::head() const noexcept {
    return head_;
  }

  bool Http1MessageRelay::started() const noexcept {
    return started_;
  }

  StreamReadiness Http1MessageRelay::sourceInterest() const noexcept {
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

  StreamReadiness Http1MessageRelay::destinationInterest() const noexcept {
    return write_offset_ != write_length_ ? write_waiting_ : StreamReadiness::none;
  }

  void Http1MessageRelay::finishHead() noexcept {
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

  void Http1MessageRelay::finishBodyBuffer() noexcept {
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

  void Http1MessageRelay::finishLine() noexcept {
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

  void Http1MessageRelay::prepareWrite(State state, std::size_t length) noexcept {
    state_ = state;
    write_offset_ = 0;
    write_length_ = length;
  }

  void Http1MessageRelay::beginLine(BodyStage stage) noexcept {
    body_stage_ = stage;
    state_ = State::reading_line;
    reader_.reset();
  }

  std::string_view Http1MessageRelay::text(std::size_t length) noexcept {
    return {reinterpret_cast<const char*>(storage_.bytes().data()), length};
  }

  template <Allocator Memory>
  const traffic::HttpPolicy& HttpInterceptionSlot<Memory>::select(traffic::HttpControl* control, const traffic::FlowEvent& event) noexcept {
    policy_ = control ? control->policy(event) : traffic::HttpPolicy{};
    collect_until_ = std::chrono::steady_clock::now() + collection_timeout;
    return policy_;
  }

  template <Allocator Memory>
  const traffic::HttpPolicy& HttpInterceptionSlot<Memory>::policy() const noexcept {
    return policy_;
  }

  template <Allocator Memory>
  auto HttpInterceptionSlot<Memory>::collectUntil() const noexcept -> Time {
    return collect_until_;
  }

  template <Allocator Memory>
  bool HttpInterceptionSlot<Memory>::waiting() const noexcept {
    return ticket_ != 0;
  }

  template <Allocator Memory>
  auto HttpInterceptionSlot<Memory>::deadline(traffic::HttpControl* control) const noexcept -> ds::Option<Time> {
    return ticket_ ? control->httpDeadline(ticket_) : ds::none;
  }

  template <Allocator Memory>
  void HttpInterceptionSlot<Memory>::release() noexcept {
    decision_.reset();
  }

  template <Allocator Memory>
  void HttpInterceptionSlot<Memory>::cancel(traffic::HttpControl* control) noexcept {
    if (ticket_) {
      control->cancelHttp(ticket_);
      ticket_ = 0;
    }

    decision_.reset();
  }

  template <Allocator Memory>
  void HttpInterceptionSlot<Memory>::unavailable(traffic::HttpControl* control, traffic::FlowEvent event, std::string_view reason) noexcept {
    event.reason = reason;
    if (control) {
      control->httpUnavailable(event);
    }

    cancel(control);
  }

  Http1InterceptedRelay::Http1InterceptedRelay(ConcurrentMemory& memory, HttpRelayContext context, bool response)
      : memory_(memory),
        secure_(memory),
        control_(context.control),
        identity_(context.identity),
        direction_(response ? traffic::Direction::inbound : traffic::Direction::outbound),
        message_(memory, response),
        wire_(AllocatorRef<Byte, Secure>{secure_}) {
    parser_.reset(response);
  }

  Http1InterceptedRelay::~Http1InterceptedRelay() {
    interception_.cancel(control_);
  }

  void Http1InterceptedRelay::reset(bool response, bool response_to_head) noexcept {
    interception_.cancel(control_);
    parser_.reset(response, response_to_head);
    message_.response = response;
    message_.response_to_head = response_to_head;
    wire_.clear();
    forwarded_head_.reset();
    original_head_.reset();
    write_offset_ = head_bytes_ = 0;
    continue_ = {};
    mode_ = Mode::undecided;
    regenerate_ = false;
    separator_lf_ = false;
    synthetic_ = head_parsed_ = false;
    destination_head_ = response_to_head;
    waiting_ = StreamReadiness::writable;
  }

  auto Http1InterceptedRelay::state() const noexcept -> State {
    if (mode_ == Mode::failed) {
      return State::failed;
    }

    if (synthetic_) {
      return hasPrefix() ? State::writing_body : State::complete;
    }

    if (parser_.state() == State::failed && mode_ == Mode::streaming && hasPrefix()) {
      return State::writing_body;
    }

    if (parser_.state() == State::complete && (mode_ == Mode::waiting || hasPrefix())) {
      return State::writing_body;
    }

    return parser_.state();
  }

  auto Http1InterceptedRelay::head() const noexcept -> const ds::Option<Http1Head>& {
    return mode_ == Mode::streaming && !hasPrefix() ? parser_.head() : forwarded_head_;
  }

  bool Http1InterceptedRelay::started() const noexcept {
    return parser_.started();
  }

  bool Http1InterceptedRelay::originalHead() const noexcept {
    return original_head_.valueOr(parser_.head() && parser_.head()->head_request);
  }

  void Http1InterceptedRelay::destinationHead(bool head) noexcept {
    destination_head_ = head;
  }

  bool Http1InterceptedRelay::captureIncomplete() const noexcept {
    return synthetic_;
  }

  auto Http1InterceptedRelay::sourceInterest() const noexcept -> StreamReadiness {
    return mode_ == Mode::failed || mode_ == Mode::waiting || (hasPrefix() && mode_ != Mode::buffering) ? StreamReadiness::none : parser_.sourceInterest();
  }

  auto Http1InterceptedRelay::destinationInterest() const noexcept -> StreamReadiness {
    if (!continue_.remaining().empty()) {
      return StreamReadiness::completion;
    }

    if (mode_ == Mode::waiting) {
      return StreamReadiness::completion;
    }

    if (mode_ == Mode::failed || mode_ == Mode::buffering) {
      return StreamReadiness::none;
    }

    return hasPrefix() ? waiting_ : parser_.destinationInterest();
  }

  auto Http1InterceptedRelay::deadline() const noexcept -> ds::Option<Time> {
    if (interception_.waiting()) {
      return interception_.deadline(control_);
    }

    return mode_ == Mode::buffering ? ds::Option{interception_.collectUntil()} : ds::none;
  }

  StaticReply& Http1InterceptedRelay::continueReplyMut() noexcept {
    return continue_;
  }

  const StaticReply& Http1InterceptedRelay::continueReply() const noexcept {
    return continue_;
  }

  bool Http1InterceptedRelay::hasPrefix() const noexcept {
    return write_offset_ != wire_.size();
  }

  void Http1InterceptedRelay::readHead(std::string_view bytes) noexcept {
    const auto& policy = interception_.select(control_, identity_.event(direction_));
    const bool repair = message_.response && message_.response_to_head != destination_head_;

    mode_ = policy.enabled || repair ? Mode::buffering : Mode::streaming;
    if (mode_ == Mode::streaming) {
      return;
    }

    try {
      const auto parsed = message_.readHttp1Head(bytes, message_.response_to_head);

      head_parsed_ = true;
      if (!message_.response) {
        original_head_ = parsed.head_request;
      }

      head_bytes_ = bytes.size();
      if (repair && destination_head_ && !policy.enabled) {
        repairHead();
        return;
      }

      if (parsed.framing.kind == Http1Framing::Kind::content_length && parsed.framing.length > maximum_wire_body) {
        unavailable("http_body_limit");
        return;
      }

      if (message_.streamingBody()) {
        unavailable("http_streaming_body");
        return;
      }

      if (!message_.response) {
        if (const auto expectation = message_.expectation(); expectation != HttpExpectation::none) {
          if (expectation != HttpExpectation::continue_) {
            unavailable("http_unsupported_expectation");
            return;
          }

          if (parsed.framing.hasBody()) {
            continue_ = StaticReply{continue_response};
          }

          regenerate_ = parsed.framing.hasBody();
          message_.headers.remove("expect");
        }
      }
    } catch (...) {
      unavailable("http_invalid_head");
    }
  }

  void Http1InterceptedRelay::unavailable(std::string_view reason) noexcept {
    if (mode_ == Mode::failed || mode_ == Mode::streaming) {
      return;
    }

    interception_.unavailable(control_, identity_.event(direction_), reason);
    mode_ = interception_.policy().fail_closed ? Mode::failed : Mode::streaming;
    if (mode_ == Mode::streaming && message_.response && message_.response_to_head != destination_head_) {
      try {
        if (head_parsed_ && destination_head_) {
          repairHead();
        } else {
          mode_ = Mode::failed;
        }
      } catch (...) {
        mode_ = Mode::failed;
      }
    }
  }

  void Http1InterceptedRelay::finish() noexcept {
    try {
      if (!message_.bodyless()) {
        message_.decodeBody(message_.body);
      }

      if (!interception_.policy().enabled || !interception_.begin(memory_, *control_, identity_.event(direction_), message_)) {
        forward(false);
        return;
      }

      mode_ = Mode::waiting;
    } catch (...) {
      unavailable("http_entity_unavailable");
    }
  }

  void Http1InterceptedRelay::resolve() noexcept {
    if (!interception_.waiting()) {
      return;
    }

    try {
      const auto outcome = interception_.poll(*control_, message_);
      if (outcome == Slot::Outcome::pending) {
        return;
      }

      // A hook's reject is reported as HTTP/2 reports a rejected stream.
      if (outcome == Slot::Outcome::rejected) {
        fail("http_interception_rejected");
        return;
      }

      forward(outcome == Slot::Outcome::replaced);
    } catch (...) {
      fail("http_invalid_decision");
    }
  }

  void Http1InterceptedRelay::forward(bool changed) {
    const bool source_head = message_.response_to_head;
    const bool repair = message_.response && source_head != destination_head_;
    if (changed || regenerate_ || repair) {
      if (message_.response) {
        message_.response_to_head = destination_head_;
      }

      try {
        // Built aside and swapped in, so a message that fails to serialize leaves the wire as it was.
        Bytes wire{AllocatorRef<Byte, Secure>{secure_}};

        message_.serializeHttp1(wire);
        wire_.swap(wire);
      } catch (...) {
        message_.response_to_head = source_head;
        throw;
      }

      message_.response_to_head = source_head;
    }

    const std::string_view text{reinterpret_cast<const char*>(wire_.data()), wire_.size()};

    head_bytes_ = text.find("\r\n\r\n") + 4;
    mode_ = Mode::forwarding;
    interception_.release();
  }

  void Http1InterceptedRelay::repairHead() {
    synthetic_ = true;
    message_.headers.set("Connection", "close");
    forward(false);
  }

  void Http1InterceptedRelay::fail(std::string_view reason) noexcept {
    interception_.unavailable(control_, identity_.event(direction_), reason);
    mode_ = Mode::failed;
  }

  template class HttpInterceptionSlot<ConcurrentMemory>;
  template class HttpInterceptionSlot<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

}
