#pragma once

#include "allocator.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
class ByteQueue {
public:
  explicit ByteQueue(Memory &memory, std::size_t limit) noexcept
      : memory_(memory),
        limit_(limit) {}

  ~ByteQueue() {
    if (bytes_ != nullptr) {
      memory_.deallocate(bytes_, capacity_, alignof(std::uint8_t));
    }
  }

  ByteQueue(const ByteQueue &) = delete;
  ByteQueue &operator=(const ByteQueue &) = delete;

  std::span<const std::uint8_t> readable() const noexcept {
    return {bytes_ == nullptr ? nullptr : bytes_ + consumed_, size()};
  }

  std::span<std::uint8_t> appendUninitialized(std::size_t count) {
    if (count > limit_ - size()) {
      throw std::bad_alloc{};
    }

    if (count > capacity_ - written_) {
      compact();
      reserve(written_ + count);
    }

    auto *start = bytes_ == nullptr ? nullptr : bytes_ + written_;
    written_ += count;
    return {start, count};
  }

  void append(std::span<const std::uint8_t> input) {
    auto output = appendUninitialized(input.size());
    std::copy(input.begin(), input.end(), output.begin());
  }

  std::span<std::uint8_t> insertUninitialized(std::size_t offset, std::size_t count) {
    const auto previous_size = size();
    assert(offset <= previous_size);
    appendUninitialized(count);
    auto *start = bytes_ + consumed_ + offset;
    std::memmove(start + count, start, previous_size - offset);
    return {start, count};
  }

  void consume(std::size_t count) noexcept {
    assert(count <= size());
    consumed_ += count;
    if (consumed_ == written_) {
      clear();
    }
  }

  void truncate(std::size_t length) noexcept {
    assert(length <= size());
    written_ = consumed_ + length;
  }

  void overwrite(std::size_t offset, std::span<const std::uint8_t> bytes) noexcept {
    assert(offset <= size() && bytes.size() <= size() - offset);
    std::memmove(bytes_ + consumed_ + offset, bytes.data(), bytes.size());
  }

  void erase(std::size_t offset, std::size_t count) noexcept {
    assert(offset <= size() && count <= size() - offset);
    if (offset == 0) {
      consume(count);
      return;
    }

    auto *start = bytes_ + consumed_ + offset;
    std::memmove(start, start + count, size() - offset - count);
    written_ -= count;
  }

  void clear() noexcept {
    written_ = 0;
    consumed_ = 0;
  }

  void reserve(std::size_t requested) {
    requested = std::min(requested, limit_);
    if (requested <= capacity_) {
      return;
    }

    const auto doubled = capacity_ > limit_ / 2 ? limit_ : capacity_ * 2;
    const auto capacity = std::max(requested, doubled);
    auto *storage = static_cast<std::uint8_t *>(memory_.allocate(capacity, alignof(std::uint8_t)));
    if (storage == nullptr) {
      throw std::bad_alloc{};
    }

    const auto retained = readable();
    std::copy(retained.begin(), retained.end(), storage);
    if (bytes_ != nullptr) {
      memory_.deallocate(bytes_, capacity_, alignof(std::uint8_t));
    }
    written_ = retained.size();
    consumed_ = 0;
    bytes_ = storage;
    capacity_ = capacity;
  }

  std::size_t size() const noexcept {
    return written_ - consumed_;
  }

  bool empty() const noexcept {
    return size() == 0;
  }

private:
  void compact() noexcept {
    if (consumed_ != 0) {
      const auto remaining = size();
      std::memmove(bytes_, bytes_ + consumed_, remaining);
      written_ = remaining;
      consumed_ = 0;
    }
  }

  Memory &memory_;
  std::size_t limit_;
  std::uint8_t *bytes_ = nullptr;
  std::size_t capacity_ = 0;
  std::size_t written_ = 0;
  std::size_t consumed_ = 0;
};

}
