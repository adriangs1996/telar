module;
#include <cstdio>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

module telar.platform.graphics;

import std;

namespace telar::runtime {

  std::optional<SharedImageStorage> SharedImageStorage::create(std::size_t length) noexcept {
    if (length == 0 || length > static_cast<std::size_t>(std::numeric_limits<off_t>::max())) {
      return std::nullopt;
    }

    SharedImageStorage storage;
    std::array<std::uint64_t, 2> nonce;

    randomBytes(nonce.data(), sizeof(nonce));
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

  SharedImageStorage::~SharedImageStorage() {
    if (name_[0] != '\0') {
      ::shm_unlink(name_.data());
    }
  }

  SharedImageStorage::SharedImageStorage(SharedImageStorage&& other) noexcept
      : name_(other.takeName()),
        mapping_(std::move(other.mapping_)) {}

  MappedRegion& SharedImageStorage::mapping() noexcept {
    return mapping_;
  }

  SharedImageStorage::Name SharedImageStorage::takeName() noexcept {
    auto name = name_;

    name_[0] = '\0';
    return name;
  }

}
