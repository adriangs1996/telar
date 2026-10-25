#pragma once

#include "../diagnostics/trace.hpp"
#include "../platform/file_descriptor.hpp"
#include "media_budget.hpp"
#include "shared_image_storage.hpp"
#include <array>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <span>
#include <string_view>
#include <sys/mman.h>

namespace telar::runtime {

template <Allocator Memory>
class FrozenImage {
public:
  explicit FrozenImage(Memory &memory, MediaAllocator<Memory> &budget, std::span<const std::uint8_t> pixels, bool shared)
      : memory_(&memory),
        budget_(&budget) {
    TELAR_TRACE("media.freezeImage");
    if (!budget_->reserve(pixels.size())) {
      throw std::bad_alloc{};
    }
    byte_count_ = pixels.size();
    reserved_bytes_ = pixels.size();

    try {
      if (shared && freezeShared(pixels)) {
        return;
      }

      pixels_ = static_cast<std::uint8_t *>(memory_->allocate(byte_count_, alignof(std::uint8_t)));
      if (pixels_ == nullptr) {
        throw std::bad_alloc{};
      }
      std::memcpy(pixels_, pixels.data(), pixels.size());
    } catch (...) {
      reset();
      throw;
    }
  }

  ~FrozenImage() {
    reset();
  }

  FrozenImage(const FrozenImage &) = delete;
  FrozenImage &operator=(const FrozenImage &) = delete;

  FrozenImage(FrozenImage &&other) noexcept {
    take(other);
  }

  FrozenImage &operator=(FrozenImage &&other) noexcept {
    if (this != &other) {
      reset();
      take(other);
    }
    return *this;
  }

  std::span<const std::uint8_t> pixels() const noexcept {
    return {pixels_, pixels_ == nullptr ? 0 : byte_count_};
  }

  std::size_t byteCount() const noexcept {
    return byte_count_;
  }

  std::string_view name() const noexcept {
    return name_.data();
  }

  void published() noexcept {
    owns_name_ = false;
  }

  static FrozenImage adoptSharedName(SharedImageStorage::Name name, std::size_t byte_count) noexcept {
    FrozenImage image;
    image.name_ = name;
    image.owns_name_ = true;
    image.byte_count_ = byte_count;
    return image;
  }

private:
  FrozenImage() noexcept = default;

  bool freezeShared(std::span<const std::uint8_t> pixels) noexcept {
    auto shared = SharedImageStorage::create(pixels.size());
    if (!shared) {
      return false;
    }

    std::memcpy(shared->mapping().bytes().data(), pixels.data(), pixels.size());
    name_ = shared->takeName();
    owns_name_ = true;
    return true;
  }

  void removeName() noexcept {
    if (owns_name_) {
      ::shm_unlink(name_.data());
    }
    name_[0] = '\0';
    owns_name_ = false;
  }

  void reset() noexcept {
    removeName();
    if (pixels_ != nullptr) {
      memory_->deallocate(pixels_, byte_count_, alignof(std::uint8_t));
      pixels_ = nullptr;
    }
    if (reserved_bytes_ != 0) {
      budget_->release(std::exchange(reserved_bytes_, 0));
    }
    byte_count_ = 0;
  }

  void take(FrozenImage &other) noexcept {
    memory_ = other.memory_;
    budget_ = other.budget_;
    pixels_ = std::exchange(other.pixels_, nullptr);
    byte_count_ = std::exchange(other.byte_count_, 0);
    reserved_bytes_ = std::exchange(other.reserved_bytes_, 0);
    name_ = other.name_;
    other.name_[0] = '\0';
    owns_name_ = std::exchange(other.owns_name_, false);
  }

  Memory *memory_ = nullptr;
  MediaAllocator<Memory> *budget_ = nullptr;
  std::uint8_t *pixels_ = nullptr;
  std::size_t byte_count_ = 0;
  std::size_t reserved_bytes_ = 0;
  std::array<char, 32> name_{};
  bool owns_name_ = false;
};

}
