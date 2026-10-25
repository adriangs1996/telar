#pragma once

#include "byte_stream.hpp"
#include <algorithm>
#include <cstring>
#include <string_view>

namespace telar::runtime {

class DelimitedRead {
public:
  enum class Result {
    pending,
    complete,
    ended,
    too_large
  };

  template <PeekableByteStream Stream>
  Result receive(Stream &source, std::span<std::uint8_t> storage, std::string_view delimiter) noexcept {
    if (complete_) {
      return Result::complete;
    }
    if (length_ == storage.size()) {
      return Result::too_large;
    }
    if constexpr (BufferedByteStream<Stream>) {
      return receiveBuffered(source, storage, delimiter);
    }

    const auto destination = storage.subspan(length_);
    const auto peeked = source.peek(destination);
    if (peeked.state != StreamResult::State::data || peeked.bytes == 0) {
      return interrupted(peeked);
    }

    const auto available = length_ + peeked.bytes;
    const auto bytes = std::string_view{reinterpret_cast<const char *>(storage.data()), available};
    const auto overlap = delimiter.size() - 1;
    const auto boundary = bytes.find(delimiter, length_ > overlap ? length_ - overlap : 0);
    const auto expected = boundary == std::string_view::npos ? available : boundary + delimiter.size();
    const auto consumed = source.read(destination.first(expected - length_));
    if (consumed.state != StreamResult::State::data || consumed.bytes == 0) {
      return interrupted(consumed);
    }

    length_ += consumed.bytes;
    waiting_ = StreamReadiness::readable;
    complete_ = boundary != std::string_view::npos && length_ == expected;
    return complete_ ? Result::complete : length_ == storage.size() ? Result::too_large
                                                                    : Result::pending;
  }

  std::size_t length() const noexcept {
    return length_;
  }

  StreamReadiness waiting() const noexcept {
    return waiting_;
  }

  void reset() noexcept {
    length_ = 0;
    complete_ = false;
    waiting_ = StreamReadiness::readable;
  }

private:
  template <BufferedByteStream Stream>
  Result receiveBuffered(Stream &source, std::span<std::uint8_t> storage, std::string_view delimiter) noexcept {
    const auto visible = source.peekView(storage.size() - length_);
    if (visible.state != StreamResult::State::data || visible.bytes.empty()) {
      return interrupted({visible.state, 0, visible.waiting});
    }

    const auto previous = std::string_view{reinterpret_cast<const char *>(storage.data()), length_};
    const auto incoming = std::string_view{reinterpret_cast<const char *>(visible.bytes.data()), visible.bytes.size()};
    const auto boundary = delimiterEnd(previous, incoming, delimiter);
    const auto consumed = boundary == std::string_view::npos ? visible.bytes.size() : boundary;
    std::memcpy(storage.data() + length_, visible.bytes.data(), consumed);
    source.consume(consumed);
    length_ += consumed;
    waiting_ = StreamReadiness::readable;
    complete_ = boundary != std::string_view::npos;
    return complete_ ? Result::complete : length_ == storage.size() ? Result::too_large
                                                                    : Result::pending;
  }

  static std::size_t delimiterEnd(std::string_view previous, std::string_view incoming, std::string_view delimiter) noexcept {
    const auto overlap = std::min(previous.size(), delimiter.size() - 1);
    for (std::size_t prefix = overlap; prefix != 0; --prefix) {
      const auto suffix = delimiter.size() - prefix;
      if (suffix <= incoming.size() && previous.ends_with(delimiter.substr(0, prefix)) && incoming.starts_with(delimiter.substr(prefix))) {
        return suffix;
      }
    }
    const auto position = incoming.find(delimiter);
    return position == std::string_view::npos ? position : position + delimiter.size();
  }

  Result interrupted(StreamResult result) noexcept {
    if (result.state == StreamResult::State::blocked) {
      waiting_ = result.waiting;
      return Result::pending;
    }
    return Result::ended;
  }

  std::size_t length_ = 0;
  bool complete_ = false;
  StreamReadiness waiting_ = StreamReadiness::readable;
};

}
