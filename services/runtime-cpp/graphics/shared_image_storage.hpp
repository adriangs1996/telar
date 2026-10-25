#pragma once

#include "../platform/file_descriptor.hpp"
#include "../platform/mapped_region.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <optional>

namespace telar::runtime {

class SharedImageStorage {
public:
  using Name = std::array<char, 32>;

  static std::optional<SharedImageStorage> create(std::size_t length) noexcept {
    if (length == 0 || length > static_cast<std::size_t>(std::numeric_limits<off_t>::max())) {
      return std::nullopt;
    }

    SharedImageStorage storage;
    std::array<std::uint64_t, 2> nonce;
    ::arc4random_buf(nonce.data(), sizeof(nonce));
    std::snprintf(storage.name_.data(), storage.name_.size(), "/tlr%016llx%08x", static_cast<unsigned long long>(nonce[0]), static_cast<unsigned>(nonce[1]));
    FileDescriptor descriptor{::shm_open(storage.name_.data(), O_CREAT | O_EXCL | O_RDWR, 0600)};
    if (!descriptor) {
      storage.name_[0] = '\0';
      return std::nullopt;
    }
    if (::ftruncate(descriptor.get(), static_cast<off_t>(length)) != 0) {
      return std::nullopt;
    }

    storage.mapping_ = MappedRegion{descriptor.get(), length, PROT_READ | PROT_WRITE};
    if (!storage.mapping_) {
      return std::nullopt;
    }
    return storage;
  }

  ~SharedImageStorage() {
    if (name_[0] != '\0') {
      ::shm_unlink(name_.data());
    }
  }

  SharedImageStorage(const SharedImageStorage &) = delete;
  SharedImageStorage &operator=(const SharedImageStorage &) = delete;

  SharedImageStorage(SharedImageStorage &&other) noexcept
      : name_(other.takeName()),
        mapping_(std::move(other.mapping_)) {}

  MappedRegion &mapping() noexcept {
    return mapping_;
  }

  Name takeName() noexcept {
    auto name = name_;
    name_[0] = '\0';
    return name;
  }

private:
  SharedImageStorage() noexcept = default;

  Name name_{};
  MappedRegion mapping_;
};

}
