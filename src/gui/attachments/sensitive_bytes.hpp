#pragma once

#include "core/memory.hpp"
#include "attachments/secure_erase.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <span>
#include <stdexcept>
#include <utility>

namespace telar::gui {

template <Allocator Memory>
class SensitiveBytes {
public:
  explicit SensitiveBytes(Memory &memory) noexcept
      : memory_(&memory) {}

  ~SensitiveBytes() {
    clear();
  }

  SensitiveBytes(const SensitiveBytes &) = delete;
  SensitiveBytes &operator=(const SensitiveBytes &) = delete;

  SensitiveBytes(SensitiveBytes &&other) noexcept
      : memory_(other.memory_),
        data_(std::exchange(other.data_, nullptr)),
        size_(std::exchange(other.size_, 0)),
        capacity_(std::exchange(other.capacity_, 0)) {}

  SensitiveBytes &operator=(SensitiveBytes &&other) noexcept {
    if (this != &other) {
      clear();
      memory_ = other.memory_;
      data_ = std::exchange(other.data_, nullptr);
      size_ = std::exchange(other.size_, 0);
      capacity_ = std::exchange(other.capacity_, 0);
    }

    return *this;
  }

  [[nodiscard]] std::span<const std::byte> view() const noexcept {
    return std::as_bytes(std::span{data_, size_});
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return size_;
  }

  [[nodiscard]] std::span<std::byte> writable() noexcept {
    return std::as_writable_bytes(std::span{data_, size_});
  }

  [[nodiscard]] std::span<std::uint8_t> unsignedBytes() noexcept {
    return {data_, size_};
  }

  [[nodiscard]] std::span<const std::uint8_t> unsignedBytes() const noexcept {
    return {data_, size_};
  }

  void resizeZeroed(std::size_t size, std::size_t limit) {
    if (size > limit) {
      throw std::length_error{"SensitiveBytesTooLarge"};
    }

    if (size > capacity_) {
      reserve(size);
    }

    if (size > size_) {
      std::fill(data_ + size_, data_ + size, std::uint8_t{});
    } else if (size < size_) {
      eraseSensitiveBytes(std::as_writable_bytes(std::span{data_ + size, size_ - size}));
    }

    size_ = size;
  }

  void append(std::span<const std::byte> bytes, std::size_t limit) {
    if (size_ > limit || bytes.size() > limit - size_) {
      throw std::length_error{"ClipboardPngTooLarge"};
    }

    const auto required = size_ + bytes.size();
    if (required > capacity_) {
      constexpr std::size_t initial_capacity = 64;
      const auto growth = capacity_ <= limit / 2 ? capacity_ + (capacity_ / 2) : limit;
      reserve(std::min(limit, std::max({required, growth, initial_capacity})));
    }

    if (!bytes.empty()) {
      if (data_ == nullptr) {
        throw std::bad_alloc{};
      }

      std::memcpy(data_ + size_, bytes.data(), bytes.size());
    }

    size_ = required;
  }

  void clear() noexcept {
    if (data_ != nullptr) {
      eraseSensitiveBytes(std::as_writable_bytes(std::span{data_, size_}));
      memory_->deallocate(data_, capacity_, alignof(std::uint8_t));
    }

    data_ = nullptr;
    size_ = 0;
    capacity_ = 0;
  }

private:
  void reserve(std::size_t capacity) {
    auto *const replacement = static_cast<std::uint8_t *>(memory_->allocate(capacity, alignof(std::uint8_t)));
    if (replacement == nullptr) {
      throw std::bad_alloc{};
    }

    if (size_ != 0) {
      std::memcpy(replacement, data_, size_);
    }

    const auto retained = size_;
    clear();
    data_ = replacement;
    size_ = retained;
    capacity_ = capacity;
  }

  Memory *memory_;
  std::uint8_t *data_ = nullptr;
  std::size_t size_ = 0;
  std::size_t capacity_ = 0;
};

}
