#pragma once

#include "core/memory.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include <concepts>

namespace telar::gui {

template <Allocator Memory>
class FrameStream {
public:
  explicit FrameStream(Memory &memory)
      : payload_(AllocatorRef<Byte, Memory>{memory}) {}

  ~FrameStream() = default;

  FrameStream(const FrameStream &) = delete;
  FrameStream &operator=(const FrameStream &) = delete;
  FrameStream(FrameStream &&) = delete;
  FrameStream &operator=(FrameStream &&) = delete;

  void reset() noexcept {
    payload_.clear();
    prefix_used_ = 0;
    expected_ = 0;
  }

  template <typename Consumer>
    requires std::invocable<Consumer &, std::span<const Byte>>
  void feed(std::span<const Byte> input, Consumer &consume) {
    while (!input.empty()) {
      if (prefix_used_ < prefix_.size()) {
        const auto count = std::min(input.size(), prefix_.size() - prefix_used_);
        std::copy_n(input.begin(), count, prefix_.begin() + prefix_used_);
        prefix_used_ += count;
        input = input.subspan(count);

        if (prefix_used_ != prefix_.size()) {
          return;
        }

        std::span<const Byte> prefix{prefix_};
        expected_ = u32::decode(prefix);
        if (expected_ == 0 || expected_ > max_payload_size) {
          throw EncodingError{"Invalid runtime frame length"};
        }

        payload_.clear();
        payload_.reserve(expected_);
      }

      const auto count = std::min(input.size(), expected_ - payload_.size());
      payload_.insert(payload_.end(), input.begin(), input.begin() + count);
      input = input.subspan(count);

      if (payload_.size() == expected_) {
        consume(std::span<const Byte>{payload_});
        prefix_used_ = 0;
      }
    }
  }

private:
  Vector<Byte, Memory> payload_;
  std::array<Byte, frame_prefix_size> prefix_{};
  std::size_t prefix_used_ = 0;
  std::size_t expected_ = 0;
};

}
