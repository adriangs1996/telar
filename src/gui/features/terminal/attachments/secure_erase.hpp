#pragma once

#include <cstddef>
#include <span>

namespace telar::gui {

  // Seen twice where a module's global fragment includes this header and the unit includes it too.
  inline void eraseSensitiveBytes(std::span<std::byte> bytes) noexcept { // NOLINT(readability-redundant-declaration): one entity, merged.
    volatile std::byte* const sensitive = bytes.data();

    for (std::size_t index = 0; index < bytes.size(); ++index) {
      sensitive[index] = std::byte{};
    }
  }

}
