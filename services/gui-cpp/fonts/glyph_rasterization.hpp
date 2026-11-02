#pragma once

#include <cstdint>
#include <limits>

namespace telar::gui::fonts {

struct GlyphRasterization {
  bool optical = false;
  std::uint8_t strength = std::numeric_limits<std::uint8_t>::max();

  [[nodiscard]] constexpr std::uint16_t key() const noexcept {
    constexpr unsigned optical_shift = std::numeric_limits<std::uint8_t>::digits;

    return optical ? static_cast<std::uint16_t>((1U << optical_shift) | strength) : 0;
  }

  bool operator==(const GlyphRasterization &) const = default;
};

}
