#pragma once

#include "../memory/sensitive_buffer.hpp"
#include "../platform/byte_stream.hpp"
#include <algorithm>
#include <cstring>

namespace telar::runtime {

class StreamPrefix {
public:
  static constexpr std::size_t capacity = 8192;

  template <ByteStream Stream>
  StreamResult fill(Stream &stream) noexcept {
    const auto result = stream.read(storage_.bytes().subspan(length_));
    if (result.state == StreamResult::State::data) { length_ += result.bytes; }
    return result;
  }
  std::span<const std::uint8_t> bytes() noexcept { return storage_.bytes().subspan(offset_, length_ - offset_); }
  bool empty() const noexcept { return offset_ == length_; }
  void consume(std::size_t count) noexcept { offset_ += count; }

private:
  SensitiveBuffer<capacity> storage_;
  std::size_t offset_ = 0;
  std::size_t length_ = 0;
};

template <PeekableByteStream Stream>
class PrefixedStream {
public:
  explicit PrefixedStream(Stream &stream, StreamPrefix &prefix) noexcept : stream_(stream), prefix_(prefix) {}
  StreamResult read(std::span<std::uint8_t> bytes) noexcept {
    if (prefix_.empty()) { return stream_.read(bytes); }
    const auto count = std::min(prefix_.bytes().size(), bytes.size());
    std::memcpy(bytes.data(), prefix_.bytes().data(), count);
    prefix_.consume(count);
    return {StreamResult::State::data, count};
  }
  StreamResult peek(std::span<std::uint8_t> bytes) noexcept {
    if (prefix_.empty()) { return stream_.peek(bytes); }
    const auto count = std::min(prefix_.bytes().size(), bytes.size());
    std::memcpy(bytes.data(), prefix_.bytes().data(), count);
    return {StreamResult::State::data, count};
  }
  StreamResult write(std::span<const std::uint8_t> bytes) noexcept { return stream_.write(bytes); }
  void halfClose() noexcept { stream_.halfClose(); }

private:
  Stream &stream_;
  StreamPrefix &prefix_;
};

}
