#pragma once

#include "../platform/delimited_read.hpp"
#include "head.hpp"
#include "observer.hpp"
#include "telar_base/memory/sensitive_buffer.hpp"
#include <algorithm>

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

  void reset(bool response, bool response_to_head = false) noexcept {
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
  bool advance(Source &source, Destination &destination, Observer &observer) noexcept {
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

  State state() const noexcept {
    return state_;
  }

  const std::optional<Http1Head> &head() const noexcept {
    return head_;
  }

  bool started() const noexcept {
    return started_;
  }

  StreamReadiness sourceInterest() const noexcept {
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

  StreamReadiness destinationInterest() const noexcept {
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
  bool readHead(Source &source, Observer &observer) noexcept {
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
  bool readBody(Source &source) noexcept {
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
  StreamView bodyInput(Source &source, std::size_t maximum) noexcept {
    if constexpr (BufferedByteStream<Source>) {
      return source.peekView(maximum);
    } else {
      const auto received = source.read(storage_.bytes().first(maximum));
      return {received.state, storage_.bytes().first(received.bytes), received.waiting};
    }
  }

  template <PeekableByteStream Source>
  bool readLine(Source &source) noexcept {
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
  bool writePending(Destination &destination, Observer &observer) noexcept {
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

  void finishHead() noexcept {
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

  void finishBodyBuffer() noexcept {
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

  void finishLine() noexcept {
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
  void recordLineLimit(Observer &observer) noexcept {
    if (line_result_ == DelimitedRead::Result::too_large) {
      observer.lineTooLong(body_stage_ == BodyStage::trailer ? Http1Line::trailer : Http1Line::chunk_size);
    }
  }

  void prepareWrite(State state, std::size_t length) noexcept {
    state_ = state;
    write_offset_ = 0;
    write_length_ = length;
    write_data_ = storage_.bytes().data();
  }

  void beginLine(BodyStage stage) noexcept {
    body_stage_ = stage;
    state_ = State::reading_line;
    reader_.reset();
  }

  std::string_view text(std::size_t length) noexcept {
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
