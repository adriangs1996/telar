#pragma once

#include "atomic_frame.hpp"
#include "child_file.hpp"
#include "child_shared_memory.hpp"

namespace telar::runtime {

class GraphicsFrameSource {
public:
  static bool available(const AtomicFrameResource &resource) noexcept {
    if (resource.byte_count > resource.limit) {
      return false;
    }

    if (resource.medium == GraphicsInputMedium::file) {
      const auto file = GraphicsChildFile::open(resource.encoded_name);
      return file && file->size >= resource.byte_count;
    }

    std::array<std::uint8_t, PATH_MAX + 1> name;
    return static_cast<bool>(GraphicsChildSharedMemory::open(resource.encoded_name, name));
  }

  static void release(const AtomicFrameResource &resource) noexcept {
    if (resource.medium == GraphicsInputMedium::shared_memory) {
      GraphicsChildSharedMemory::release(resource.encoded_name);
    }
  }
};

}
