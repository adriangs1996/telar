#pragma once

#include <cstddef>
#include <span>

namespace telar::gui {

  // Seen twice where a module's global fragment includes this header and the unit includes it too.
  inline void eraseSensitiveBytes(std::span<std::byte> bytes) noexcept { // NOLINT(readability-redundant-declaration): one entity, merged.
    // Each write is volatile, so the compiler keeps the ones that nothing reads afterwards.
    for (std::size_t index = 0; index < bytes.size(); ++index) { // NOLINT(modernize-loop-convert): misc-const-correctness sees no write through a range-for's element under the volatile cast
      static_cast<volatile std::byte&>(bytes[index]) = std::byte{};
    }
  }

}
