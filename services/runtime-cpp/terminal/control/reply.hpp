#pragma once

#include "../../memory/allocator.hpp"
#include "../pty_response_queue.hpp"
#include <array>
#include <charconv>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::control {

template <Allocator Memory>
class Reply {
  struct Storage {
    explicit Storage(Vector<std::uint8_t, Memory> &&bytes) : bytes(std::move(bytes)) {}

    Vector<std::uint8_t, Memory> bytes;
  };

public:
  static constexpr std::size_t maximum_bytes = PtyResponseQueue::total_byte_capacity;

  explicit Reply(Memory &memory) : memory_(memory), overflow_(AllocatorRef<std::uint8_t, Memory>{memory}) {}

  void append(std::string_view text) {
    if (text.empty()) {
      return;
    }
    if (text.size() > maximum_bytes - size_) {
      throw std::length_error{"Control reply exceeds its configured limit"};
    }

    if (size_ + text.size() <= inline_.size()) {
      std::memcpy(inline_.data() + size_, text.data(), text.size());
    } else {
      if (overflow_.empty()) {
        overflow_.reserve(std::max(inline_.size() * 2, size_ + text.size()));
        overflow_.insert(overflow_.end(), inline_.begin(), inline_.begin() + size_);
      }
      if (size_ + text.size() > overflow_.capacity()) {
        overflow_.reserve(std::min(maximum_bytes, std::max(size_ + text.size(), overflow_.capacity() * 2)));
      }
      overflow_.insert(overflow_.end(), text.begin(), text.end());
    }
    size_ += text.size();
  }

  void number(std::uint64_t value) {
    std::array<char, std::numeric_limits<std::uint64_t>::digits10 + 1> bytes;
    const auto formatted = std::to_chars(bytes.data(), bytes.data() + bytes.size(), value);
    append({bytes.data(), static_cast<std::size_t>(formatted.ptr - bytes.data())});
  }

  void hex(std::uint64_t value, unsigned width, bool upper = false) {
    constexpr std::string_view lower_digits = "0123456789abcdef";
    constexpr std::string_view upper_digits = "0123456789ABCDEF";
    std::array<char, sizeof(value) * 2> bytes;
    width = std::min<unsigned>(width, bytes.size());
    const auto digits = upper ? upper_digits : lower_digits;
    auto offset = bytes.size();
    do {
      bytes[--offset] = digits[value & (digits.size() - 1)];
      value >>= 4;
    } while (value != 0);
    while (bytes.size() - offset < width) {
      bytes[--offset] = '0';
    }
    append({bytes.data() + offset, bytes.size() - offset});
  }

  template <typename Sink>
  bool publish(Sink &queue) {
    if (size_ == 0) {
      return true;
    }

    if (size_ <= inline_.size()) {
      return queue.tryPush(std::span<const std::uint8_t>{inline_}.first(size_));
    }

    seal();
    return queue.tryPushOwned(owned_->bytes, owned_);
  }

  void seal() {
    if (size_ > inline_.size() && !owned_) {
      owned_ = std::allocate_shared<Storage>(AllocatorRef<Storage, Memory>{memory_}, std::move(overflow_));
    }
  }

  void clear() noexcept {
    size_ = 0;
    overflow_.clear();
    owned_.reset();
  }

  std::size_t size() const noexcept {
    return size_;
  }

private:
  Memory &memory_;
  std::array<std::uint8_t, PtyResponseQueue::message_byte_capacity> inline_;
  Vector<std::uint8_t, Memory> overflow_;
  std::shared_ptr<Storage> owned_;
  std::size_t size_ = 0;
};

}
