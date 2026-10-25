#pragma once

#include <cstdint>
#include <span>
#include <sys/mman.h>
#include <utility>

namespace telar::runtime {

class MappedRegion {
public:
  MappedRegion() noexcept = default;

  explicit MappedRegion(int descriptor, std::size_t length, int protection) noexcept {
    void *address = ::mmap(nullptr, length, protection, MAP_SHARED, descriptor, 0);
    if (address != MAP_FAILED) {
      bytes_ = {static_cast<std::uint8_t *>(address), length};
    }
  }

  ~MappedRegion() {
    reset();
  }

  MappedRegion(const MappedRegion &) = delete;
  MappedRegion &operator=(const MappedRegion &) = delete;

  MappedRegion(MappedRegion &&other) noexcept
      : bytes_(std::exchange(other.bytes_, {})) {}

  MappedRegion &operator=(MappedRegion &&other) noexcept {
    if (this != &other) {
      reset();
      bytes_ = std::exchange(other.bytes_, {});
    }
    return *this;
  }

  explicit operator bool() const noexcept {
    return !bytes_.empty();
  }

  std::span<std::uint8_t> bytes() const noexcept {
    return bytes_;
  }

  bool protect(int protection) noexcept {
    return ::mprotect(bytes_.data(), bytes_.size(), protection) == 0;
  }

private:
  void reset() noexcept {
    if (!bytes_.empty()) {
      ::munmap(bytes_.data(), bytes_.size());
      bytes_ = {};
    }
  }

  std::span<std::uint8_t> bytes_;
};

}
