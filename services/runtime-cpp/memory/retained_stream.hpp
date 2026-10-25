#pragma once

#include "allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstring>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
class RetainedStream {
public:
  explicit RetainedStream(Memory &memory, std::size_t capacity)
      : memory_(memory),
        capacity_(capacity) {
    bytes_ = static_cast<Byte *>(memory_.allocate(capacity_, alignof(Byte)));
    if (bytes_ == nullptr) {
      throw std::bad_alloc{};
    }
  }

  ~RetainedStream() {
    memory_.deallocate(bytes_, capacity_, alignof(Byte));
  }

  RetainedStream(const RetainedStream &) = delete;
  RetainedStream &operator=(const RetainedStream &) = delete;

  void append(std::span<const Byte> bytes) noexcept {
    total_ += bytes.size();
    bytes = bytes.last(std::min(bytes.size(), capacity_));
    const auto start = static_cast<std::size_t>((total_ - bytes.size()) % capacity_);
    const auto first = std::min(bytes.size(), capacity_ - start);
    std::memcpy(bytes_ + start, bytes.data(), first);
    std::memcpy(bytes_, bytes.data() + first, bytes.size() - first);
  }

  std::span<const Byte> read(std::uint64_t offset, std::span<Byte> destination) const noexcept {
    if (offset < retainedOffset() || offset >= total_) {
      return {};
    }

    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(destination.size(), total_ - offset));
    const auto start = static_cast<std::size_t>(offset % capacity_);
    const auto first = std::min(count, capacity_ - start);
    std::memcpy(destination.data(), bytes_ + start, first);
    std::memcpy(destination.data() + first, bytes_, count - first);
    return destination.first(count);
  }

  std::uint64_t total() const noexcept {
    return total_;
  }

  std::uint64_t retainedOffset() const noexcept {
    return total_ - std::min<std::uint64_t>(total_, capacity_);
  }

private:
  Memory &memory_;
  Byte *bytes_;
  std::size_t capacity_;
  std::uint64_t total_ = 0;
};

template <Allocator Memory>
RetainedStream(Memory &memory, std::size_t capacity) -> RetainedStream<Memory>;

}
