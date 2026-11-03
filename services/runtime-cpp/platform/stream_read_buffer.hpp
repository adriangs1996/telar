#pragma once

#include "byte_stream.hpp"
#include "telar_base/memory/sensitive_buffer.hpp"
#include <algorithm>
#include <cassert>
#include <cstring>

namespace telar::runtime {

template <std::size_t Capacity>
class StreamReadBuffer {
public:
  template <typename Read>
    requires requires(Read read, std::span<std::uint8_t> destination) {
      { read(destination) } noexcept -> std::same_as<StreamResult>;
    }
  StreamView peek(Read read, std::size_t maximum) noexcept {
    if (empty()) {
      const auto received = read(storage_.bytes());
      if (received.state != StreamResult::State::data || received.bytes == 0) {
        return {received.state, {}, received.waiting};
      }
      offset_ = 0;
      length_ = received.bytes;
    }
    return {StreamResult::State::data, storage_.bytes().subspan(offset_, std::min(maximum, length_ - offset_))};
  }

  std::size_t copyTo(std::span<std::uint8_t> destination) noexcept {
    const auto count = std::min(destination.size(), length_ - offset_);
    if (count != 0) {
      std::memcpy(destination.data(), storage_.bytes().data() + offset_, count);
      consume(count);
    }
    return count;
  }

  void consume(std::size_t count) noexcept {
    assert(count <= length_ - offset_);
    offset_ += count;
  }

  bool empty() const noexcept {
    return offset_ == length_;
  }

private:
  SensitiveBuffer<Capacity> storage_;
  std::size_t offset_ = 0;
  std::size_t length_ = 0;
};

}
