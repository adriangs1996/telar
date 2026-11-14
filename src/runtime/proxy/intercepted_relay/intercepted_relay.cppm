module;
#include "tbc/hot_path.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstdint>

#include <cstddef>
#include <cstring>

#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>
#include <zstd.h>

export module telar.runtime.proxy.intercepted_relay;

import std;
import telar.tbc;

export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.http1.head;

export import telar.base.memory.allocators;
export import telar.base.memory.sensitive;

export import telar.runtime.http.message;
export import telar.runtime.traffic.control_protocol;
import telar.base.diagnostics;
import telar.base.text;

// Interface: http1/observer.cppm
export {
  namespace telar::runtime {

    enum class Http1Line {
      chunk_size,
      trailer,
    };

    template <typename Observer>
    concept Http1Observer = requires(Observer& observer, std::string_view head, std::span<const std::uint8_t> payload, Http1Line line) {
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
        head_too_large,
      };

      void reset(bool response, bool response_to_head = false) noexcept;

      // Generic over the caller's streams and observer, and called for every read the relay makes.
      template <PeekableByteStream Source, ByteStream Destination, Http1Observer Observer>
      TBC_HOT_PATH bool advance(Source& source, Destination& destination, Observer& observer) noexcept {
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
            // A borrowed body fragment stays in the source, stable through every write retry, until it is
            // consumed; everything else waits in the relay's own storage.
            const bool body_pending = state_ == State::writing_body;
            std::span<const std::uint8_t> pending = storage_.bytes().first(std::min(write_length_, storage_.bytes().size()));

            if constexpr (BufferedByteStream<Source>) {
              if (body_pending) {
                pending = source.peekView(write_length_).bytes;
              }
            }

            if (pending.size() != write_length_) {
              state_ = State::failed;
              return active_;
            }

            continued = writePending(destination, observer, pending);
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

      State state() const noexcept;

      const std::optional<Http1Head>& head() const noexcept;

      bool started() const noexcept;

      StreamReadiness sourceInterest() const noexcept;

      StreamReadiness destinationInterest() const noexcept;

    private:
      enum class BodyStage {
        content,
        until_close,
        chunk_size,
        chunk_payload,
        chunk_separator,
        trailer,
      };

      template <PeekableByteStream Source, Http1Observer Observer>
      TBC_HOT_PATH bool readHead(Source& source, Observer& observer) noexcept {
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
      TBC_HOT_PATH bool readBody(Source& source) noexcept {
        const auto capacity = body_stage_ == BodyStage::until_close ? body_capacity : std::min(remaining_, body_capacity);
        const auto received = bodyInput(source, capacity);
        if (received.state == StreamResult::State::blocked) {
          read_waiting_ = received.waiting;
          return false;
        }

        if (received.state != StreamResult::State::data || received.bytes == 0) {
          state_ = body_stage_ == BodyStage::until_close ? State::complete : State::failed;
          return false;
        }

        active_ = true;
        read_waiting_ = StreamReadiness::readable;
        if (body_stage_ != BodyStage::until_close) {
          remaining_ -= received.bytes;
        }

        prepareWrite(State::writing_body, received.bytes);
        return true;
      }

      // How much body arrived: in the source until it is consumed, or read into the relay's storage.
      template <ByteStream Source>
      TBC_HOT_PATH StreamResult bodyInput(Source& source, std::size_t maximum) noexcept {
        if constexpr (BufferedByteStream<Source>) {
          const auto peeked = source.peekView(maximum);

          return {peeked.state, peeked.bytes.size(), peeked.waiting};
        } else {
          return source.read(storage_.bytes().first(maximum));
        }
      }

      template <PeekableByteStream Source>
      TBC_HOT_PATH bool readLine(Source& source) noexcept {
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
      TBC_HOT_PATH bool writePending(Destination& destination, Observer& observer, std::span<const std::uint8_t> pending) noexcept {
        const auto sent = destination.write(pending.subspan(write_offset_));
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
            if (body_stage_ == BodyStage::chunk_separator) {
              observer.chunkSeparator(pending);
            }
          }

          observer.payload(body_stage_ == BodyStage::chunk_separator ? std::span<const std::uint8_t>{} : pending);
          finishBodyBuffer();
          break;
        case State::writing_line:
          recordLineLimit(observer);
          if constexpr (requires { { observer.chunkLine(std::string_view{}) } noexcept -> std::same_as<void>; }) {
            if (body_stage_ == BodyStage::chunk_size && line_result_ == DelimitedRead::Result::complete) {
              observer.chunkLine(text(write_length_));
            }
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

      void finishHead() noexcept;

      void finishBodyBuffer() noexcept;

      void finishLine() noexcept;

      template <Http1Observer Observer>
      TBC_HOT_PATH void recordLineLimit(Observer& observer) noexcept {
        if (line_result_ == DelimitedRead::Result::too_large) {
          observer.lineTooLong(body_stage_ == BodyStage::trailer ? Http1Line::trailer : Http1Line::chunk_size);
        }
      }

      void prepareWrite(State state, std::size_t length) noexcept;

      void beginLine(BodyStage stage) noexcept;

      std::string_view text(std::size_t length) noexcept;

      static constexpr std::size_t body_capacity = 16 * 1024;
      static constexpr std::size_t chunk_separator_bytes = 2;
      static constexpr std::size_t maximum_rounds = 32;
      SensitiveBuffer<Http1Head::capacity> storage_;
      DelimitedRead reader_;
      std::optional<Http1Head> head_;
      std::size_t remaining_ = 0;
      std::size_t write_length_ = 0;
      std::size_t write_offset_ = 0;
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

// Interface: http/interception_slot.cppm
export {
  namespace telar::runtime {

    // One message's interception: the policy its head selects, the time it may take to collect, and
    // the hook's ticket with the buffer its decision lands in.
    template <Allocator Memory>
    class HttpInterceptionSlot {
    public:
      using Time = traffic::FlowControl::Time;
      enum class Outcome {
        pending,
        rejected,
        allowed,
        replaced,
      };
      static constexpr auto collection_timeout = std::chrono::seconds{30};

      // Takes the policy `control` sets for `event`'s message, and starts the time to collect it.
      const traffic::HttpPolicy& select(traffic::HttpControl* control, const traffic::FlowEvent& event) noexcept;

      const traffic::HttpPolicy& policy() const noexcept;

      Time collectUntil() const noexcept;

      bool waiting() const noexcept;

      // Offers the complete message to the hook; false when the hook takes no ticket, so the message
      // goes on as it is.
      // The slot keeps an allocation of `memory`, region `a`, until the decision is released.
      template <typename Message>
      TBC_HOT_PATH bool begin(tbc::view<Memory&, tbc::lt::a> memory, traffic::HttpControl& control, traffic::FlowEvent event, const Message& message) {
        decision_.emplace(memory, HttpMessageLimits::message_bytes);
        event.bytes = HttpMessageCodec::encodeMessage(decision_->bytes(), message);
        ticket_ = control.interceptHttp(event);
        return ticket_ != 0;
      }

      // The hook's verdict, once it has one; a replacement is read into `message`, which throws when
      // the hook's bytes are no message.
      template <typename Message>
      TBC_HOT_PATH Outcome poll(traffic::HttpControl& control, Message& message) {
        const auto decision = control.pollHttp(ticket_, decision_->bytes());
        if (decision.verdict == traffic::Verdict::pending) {
          return Outcome::pending;
        }

        ticket_ = 0;
        if (decision.verdict == traffic::Verdict::reject) {
          return Outcome::rejected;
        }

        if (decision.verdict != traffic::Verdict::replace) {
          return Outcome::allowed;
        }

        HttpMessageCodec::readMessage(message, decision_->bytes().first(decision.bytes));
        return Outcome::replaced;
      }

      std::optional<Time> deadline(traffic::HttpControl* control) const noexcept;

      // Frees the decision once the message went on.
      void release() noexcept;

      void cancel(traffic::HttpControl* control) noexcept;

      // Tells the control the message cannot be intercepted, for `reason`, and gives up the ticket.
      void unavailable(traffic::HttpControl* control, traffic::FlowEvent event, std::string_view reason) noexcept;

    private:
      traffic::HttpPolicy policy_;
      Time collect_until_{};
      std::uint64_t ticket_ = 0;
      tbc::view<std::optional<SensitiveAllocation<Memory>>, tbc::lt::a> decision_;
    };

    extern template class HttpInterceptionSlot<SynchronizedAllocator<BudgetAllocator<ConcurrentMemory>>>;

    extern template class HttpInterceptionSlot<ConcurrentMemory>;

  }
}

// Interface: http1/intercepted_relay.cppm
export {
  namespace telar::runtime {

    struct HttpRelayContext {
      traffic::HttpControl* control = nullptr;
      traffic::FlowEvent event;
    };

    // The parser retains a blocked fragment while a buffered prefix drains during fail-open fallback.
    template <ConcurrentAllocator Memory>
    class Http1InterceptedRelay {
      using Secure = ErasingAllocator<Memory>;
      using Bytes = Vector<Byte, Secure>;
      enum class Mode {
        undecided,
        buffering,
        waiting,
        forwarding,
        streaming,
        failed,
      };

      // Generic over the caller's observer.
      template <Http1Observer Observer>
      struct TBC_HOT_PATH Observation {
        Http1InterceptedRelay& relay;
        Observer& next;

        inline void headStarted() noexcept {
          next.headStarted();
        }

        inline void head(std::string_view bytes) noexcept {
          next.head(bytes);
          relay.readHead(bytes);
        }

        inline void payload(std::span<const Byte> bytes) noexcept {
          next.payload(bytes);
          if (relay.mode_ != Mode::buffering) {
            return;
          }

          try {
            if (bytes.size() > maximum_wire_body - relay.message_.body.size()) {
              relay.unavailable("http_body_limit");
              return;
            }

            relay.message_.body.insert(relay.message_.body.end(), bytes.begin(), bytes.end());
          } catch (...) {
            relay.unavailable("http_allocation_failed");
          }
        }

        inline void trailer(std::string_view line) noexcept {
          if (relay.mode_ != Mode::buffering) {
            return;
          }

          try {
            const auto colon = line.find(':');
            if (colon == std::string_view::npos) {
              relay.unavailable("http_invalid_trailer");
              return;
            }

            relay.message_.trailers.append(line.substr(0, colon), trimText(line.substr(colon + 1), " \t"));
          } catch (...) {
            relay.unavailable("http_invalid_trailer");
          }
        }

        inline void chunkLine(std::string_view line) noexcept {
          if (relay.mode_ != Mode::buffering) {
            return;
          }

          if (!line.ends_with("\r\n")) {
            relay.unavailable("http_invalid_chunk_size");
            return;
          }

          line.remove_suffix(2);
          if (std::ranges::any_of(line, [](unsigned char byte) {
                return (byte < 32 && byte != '\t') || byte == 127;
              })) {
            relay.unavailable("http_invalid_chunk_size");
            return;
          }

          const auto size = trimText(line.substr(0, line.find(';')), " \t");
          if (size.empty() || !std::ranges::all_of(size, [](unsigned char byte) {
                return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f');
              })) {
            relay.unavailable("http_invalid_chunk_size");
          }
        }

        inline void chunkSeparator(std::span<const Byte> bytes) noexcept {
          if (relay.mode_ != Mode::buffering) {
            return;
          }

          for (const auto byte : bytes) {
            if (byte != (relay.separator_lf_ ? '\n' : '\r')) {
              relay.unavailable("http_invalid_chunk_separator");
              return;
            }

            relay.separator_lf_ = !relay.separator_lf_;
          }
        }

        inline void lineTooLong(Http1Line line) noexcept {
          next.lineTooLong(line);
          relay.unavailable("http_line_limit");
        }
      };

      // Generic over the caller's destination.
      template <ByteStream Destination>
      struct TBC_HOT_PATH Sink {
        Http1InterceptedRelay& relay;
        Destination& destination;

        inline StreamResult read(std::span<Byte>) noexcept {
          return {StreamResult::State::failed};
        }

        inline void halfClose() noexcept {}

        inline StreamResult write(std::span<const Byte> bytes) noexcept {
          if (relay.mode_ == Mode::failed) {
            return {StreamResult::State::failed};
          }

          if (relay.synthetic_) {
            return {StreamResult::State::blocked, 0, StreamReadiness::completion};
          }

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

      // The relay copies the flow's identity, so its events view the relay and not the flow.
      Http1InterceptedRelay(Memory& memory, HttpRelayContext context, bool response);

      ~Http1InterceptedRelay();

      void reset(bool response, bool response_to_head = false) noexcept;

      // Generic over the caller's streams and observer, and called for every read the relay makes.
      template <PeekableByteStream Source, ByteStream Destination, Http1Observer Observer>
      TBC_HOT_PATH bool advance(Source& source, Destination& destination, Observer& observer) noexcept {
        if (mode_ == Mode::failed) {
          return false;
        }

        if (mode_ == Mode::buffering && std::chrono::steady_clock::now() >= interception_.collectUntil()) {
          unavailable("http_collection_timeout");
        }

        bool active = flush(destination);

        if (synthetic_) {
          return active;
        }

        if (mode_ == Mode::waiting) {
          resolve();
          active = flush(destination) || active;
        }

        if (mode_ == Mode::failed || mode_ == Mode::waiting || (hasPrefix() && mode_ != Mode::buffering)) {
          return active;
        }

        Sink<Destination> sink{*this, destination};
        Observation<Observer> observation{*this, observer};

        active = parser_.advance(source, sink, observation) || active;
        if (mode_ == Mode::buffering && parser_.state() == State::failed) {
          unavailable("http_incomplete_message");
        }

        if (mode_ == Mode::buffering && parser_.state() == State::complete) {
          finish();
        }

        if (mode_ == Mode::waiting) {
          resolve();
        }

        return flush(destination) || active;
      }

      auto state() const noexcept -> State;

      auto head() const noexcept -> const std::optional<Http1Head>&;

      bool started() const noexcept;

      bool originalHead() const noexcept;

      void destinationHead(bool head) noexcept;

      bool captureIncomplete() const noexcept;

      auto sourceInterest() const noexcept -> StreamReadiness;

      auto destinationInterest() const noexcept -> StreamReadiness;

      auto deadline() const noexcept -> std::optional<Time>;

      // The 100 Continue the child waits for before it sends a body; empty unless it asked.
      StaticReply& continueReply() noexcept;

      const StaticReply& continueReply() const noexcept;

    private:
      bool hasPrefix() const noexcept;

      void readHead(std::string_view bytes) noexcept;

      void unavailable(std::string_view reason) noexcept;

      void finish() noexcept;

      void resolve() noexcept;

      void forward(bool changed);

      void repairHead();

      template <ByteStream Destination>
      TBC_HOT_PATH bool flush(Destination& destination) noexcept {
        if (!continue_.remaining().empty()) {
          return false;
        }

        if (!hasPrefix() || (mode_ != Mode::forwarding && mode_ != Mode::streaming)) {
          return false;
        }

        const auto written = destination.write(std::span{wire_}.subspan(write_offset_));
        if (written.state == StreamResult::State::blocked) {
          waiting_ = written.waiting;
          return false;
        }

        if (written.state != StreamResult::State::data || written.bytes == 0) {
          mode_ = Mode::failed;
          return false;
        }

        write_offset_ += written.bytes;
        waiting_ = StreamReadiness::writable;
        if (!forwarded_head_ && write_offset_ >= head_bytes_) {
          forwarded_head_ = Http1Head::analyze({reinterpret_cast<const char*>(wire_.data()), head_bytes_}, message_.response, message_.response ? destination_head_ : message_.response_to_head);
          if (forwarded_head_ && parser_.head() && parser_.head()->closes) {
            forwarded_head_->closes = true;
          }
        }

        if (!hasPrefix()) {
          wire_.clear();
          write_offset_ = 0;
        }

        return true;
      }

      // Fails the message after its interception ended, reporting why.
      void fail(std::string_view reason) noexcept;

      static constexpr std::size_t maximum_wire_body = HttpMessageLimits::body_bytes + Http1Head::capacity;
      static constexpr std::string_view continue_response = "HTTP/1.1 100 Continue\r\n\r\n";
      Memory& memory_;
      Secure secure_;
      traffic::HttpControl* control_;
      traffic::FlowIdentity identity_;
      traffic::Direction direction_;
      HttpMessage<Memory> message_;
      Bytes wire_;
      using Slot = HttpInterceptionSlot<Memory>;
      Slot interception_;
      Http1MessageRelay parser_;
      std::optional<Http1Head> forwarded_head_;
      std::optional<bool> original_head_;
      std::size_t write_offset_ = 0, head_bytes_ = 0;
      StaticReply continue_;
      StreamReadiness waiting_ = StreamReadiness::writable;
      Mode mode_ = Mode::undecided;
      bool regenerate_ = false;
      bool separator_lf_ = false;
      bool destination_head_ = false, synthetic_ = false, head_parsed_ = false;
    };

    extern template class Http1InterceptedRelay<ConcurrentMemory>;

  }
}
