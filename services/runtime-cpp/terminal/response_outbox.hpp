#pragma once

#include "pty_response_queue.hpp"
#include "../memory/allocator.hpp"
#include <stdexcept>

namespace telar::runtime {

// One producer owns these staged messages. Queue publication copies complete
// records; a blocked record is never executed or generated a second time.
template <Allocator Memory>
class ResponseOutbox {
public:
  explicit ResponseOutbox(Memory &memory, PtyResponseQueue &queue)
      : overflow_(AllocatorRef<std::uint8_t, Memory>{memory}), queue_(queue) {}

  ~ResponseOutbox() { discard(); }

  ResponseOutbox(const ResponseOutbox &) = delete;
  ResponseOutbox &operator=(const ResponseOutbox &) = delete;

  void append(std::span<const std::uint8_t> response) {
    if (response.empty() || queue_.closed()) {
      return;
    }
    if (response.size() > PtyResponseQueue::message_byte_capacity || response.size() + header_bytes > maximum_bytes - size_) {
      throw std::length_error{"Graphics acknowledgement exceeds its staging budget"};
    }
    const auto length = static_cast<std::uint16_t>(response.size());
    const auto required = size_ + header_bytes + response.size();
    if (overflow_.empty() && required <= inline_.size()) {
      std::memcpy(inline_.data() + size_, &length, header_bytes);
      std::memcpy(inline_.data() + size_ + header_bytes, response.data(), response.size());
    } else {
      if (required > overflow_.capacity()) {
        overflow_.reserve(std::min(maximum_bytes, std::max(required, std::max(inline_bytes * 2, overflow_.capacity() * 2))));
      }
      if (overflow_.empty()) {
        overflow_.insert(overflow_.end(), inline_.begin(), inline_.begin() + size_);
      }
      const auto *header = reinterpret_cast<const std::uint8_t *>(&length);
      overflow_.insert(overflow_.end(), header, header + header_bytes);
      overflow_.insert(overflow_.end(), response.begin(), response.end());
    }
    size_ = required;
    if (!priority_) {
      priority_ = queue_.retainWorkerPriority();
    }
  }

  bool drain() noexcept {
    if (queue_.closed()) {
      discard();
      return true;
    }
    while (pending()) {
      const auto count = nextSize();
      const auto *data = overflow_.empty() ? inline_.data() : overflow_.data();
      if (!queue_.tryPush({data + consumed_ + header_bytes, count})) {
        return false;
      }
      consumed_ += header_bytes + count;
    }
    discard();
    return true;
  }

  void discard() noexcept {
    size_ = 0;
    consumed_ = 0;
    Vector<std::uint8_t, Memory>{overflow_.get_allocator()}.swap(overflow_);
    if (priority_) {
      queue_.releaseWorkerPriority();
      priority_ = false;
    }
  }

  bool pending() const noexcept { return consumed_ != size_; }

  std::size_t nextSize() const noexcept {
    if (!pending()) {
      return 0;
    }
    const auto *data = overflow_.empty() ? inline_.data() : overflow_.data();
    std::uint16_t length;
    std::memcpy(&length, data + consumed_, header_bytes);
    assert(length <= size_ - consumed_ - header_bytes);
    return length;
  }

private:
  static constexpr std::size_t inline_bytes = 2048;
  static constexpr std::size_t maximum_bytes = PtyResponseQueue::total_byte_capacity;
  static constexpr std::size_t header_bytes = sizeof(std::uint16_t);
  std::array<std::uint8_t, inline_bytes> inline_;
  Vector<std::uint8_t, Memory> overflow_;
  PtyResponseQueue &queue_;
  std::size_t size_ = 0;
  std::size_t consumed_ = 0;
  bool priority_ = false;
};

}
