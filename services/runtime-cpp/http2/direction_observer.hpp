#pragma once

#include "observer.hpp"

namespace telar::runtime {

template <Allocator Memory>
class Http2DirectionObserver {
public:
  static constexpr std::string_view client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

  explicit Http2DirectionObserver(Memory &memory, Http2Direction direction) noexcept : observer_(memory, direction), direction_(direction) {}

  template <Http2EventSink Sink>
  void observe(std::span<const std::uint8_t> bytes, Sink &sink) noexcept {
    if (direction_ == Http2Direction::request && preface_offset_ < client_preface.size()) {
      const auto count = std::min(client_preface.size() - preface_offset_, bytes.size());
      if (std::memcmp(bytes.data(), client_preface.data() + preface_offset_, count) != 0) {
        observer_.fail();
      }
      preface_offset_ += count;
      bytes = bytes.subspan(count);
    }
    observer_.observe(bytes, sink);
  }

  typename Http2Observer<Memory>::Statistics finish() noexcept {
    if (direction_ == Http2Direction::request && preface_offset_ != client_preface.size()) {
      observer_.fail();
    }
    return observer_.finish();
  }

private:
  Http2Observer<Memory> observer_;
  Http2Direction direction_;
  std::size_t preface_offset_ = 0;
};

}
