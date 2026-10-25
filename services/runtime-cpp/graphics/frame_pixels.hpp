#pragma once

#include "../platform/mapped_region.hpp"
#include "frame_source.hpp"
#include <cstring>

namespace telar::runtime {

class GraphicsFramePixels {
public:
  static std::optional<GraphicsFramePixels> open(const AtomicFrameResource &resource) noexcept {
    if (resource.byte_count == 0 || resource.byte_count > resource.limit) {
      return std::nullopt;
    }

    GraphicsFramePixels pixels;
    if (resource.medium == GraphicsInputMedium::file) {
      pixels.file_ = GraphicsChildFile::open(resource.encoded_name);
      if (!pixels.file_ || pixels.file_->size < resource.byte_count) {
        return std::nullopt;
      }
      return pixels;
    }

    std::array<std::uint8_t, PATH_MAX + 1> name;
    const auto shared = GraphicsChildSharedMemory::open(resource.encoded_name, name);
    struct stat metadata{};
    if (!shared || ::fstat(shared.get(), &metadata) != 0 || metadata.st_size < 0 || static_cast<std::uint64_t>(metadata.st_size) < resource.byte_count) {
      return std::nullopt;
    }

    pixels.mapping_ = MappedRegion{shared.get(), resource.byte_count, PROT_READ};
    if (!pixels.mapping_) {
      return std::nullopt;
    }
    ::shm_unlink(reinterpret_cast<const char *>(name.data()));
    return pixels;
  }

  bool copyTo(std::span<std::uint8_t> destination) const noexcept {
    if (file_) {
      return file_->read(destination, 0);
    }
    if (destination.size() != mapping_.bytes().size()) {
      return false;
    }

    std::memcpy(destination.data(), mapping_.bytes().data(), destination.size());
    return true;
  }

private:
  std::optional<GraphicsChildFile> file_;
  MappedRegion mapping_;
};

}
