#pragma once

#include <cstddef>

namespace telar::runtime {

struct GraphicsLimits {
  static constexpr std::size_t mebibyte = 1024 * 1024;
  static constexpr std::size_t maximum_pane_bytes = 256 * mebibyte;
  static constexpr std::size_t maximum_global_bytes = 512 * mebibyte;
  static constexpr std::size_t payload_bytes = 64 * 1024;
  static constexpr std::size_t recommended_chunk_bytes = 3072;
  static constexpr std::size_t maximum_chunks_per_image = maximum_pane_bytes / 2 / recommended_chunk_bytes;

  std::size_t pane_bytes = maximum_pane_bytes;
  std::size_t global_bytes = maximum_global_bytes;

  std::size_t screenBytes() const noexcept {
    return pane_bytes / 2;
  }
};

}
