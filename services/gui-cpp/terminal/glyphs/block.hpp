#pragma once

#include "core/geometry.hpp"
#include "ink.hpp"
#include "symbol.hpp"
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace telar::gui::glyphs {

class Block {
public:
  using Paint = Ink<2>;

  [[nodiscard]] static Paint draw(Rect cell, std::uint32_t codepoint) {
    validateCell(cell);
    if (codepoint < Symbol::first_block || codepoint > Symbol::last_block) {
      throw std::invalid_argument{"InvalidBlockElement"};
    }

    auto result = build(cell, codepoint);
    result.translate({.x = cell.x, .y = cell.y});

    return result;
  }

private:
  static constexpr unsigned upper_left = 1;
  static constexpr unsigned upper_right = 2;
  static constexpr unsigned lower_left = 4;
  static constexpr unsigned lower_right = 8;

  [[nodiscard]] static Paint build(Rect cell, std::uint32_t codepoint) {
    constexpr std::uint32_t lower_full = 0x2588;
    constexpr std::uint32_t left_first = 0x2589;
    constexpr std::uint32_t right_half = 0x2590;
    constexpr std::uint32_t first_shade = 0x2591;
    constexpr std::uint32_t last_shade = 0x2593;
    constexpr std::uint32_t top_eighth = 0x2594;
    constexpr std::uint32_t right_eighth = 0x2595;

    if (codepoint == Symbol::first_block || codepoint == top_eighth) {
      return slab(cell, Side::top, codepoint == top_eighth ? 1 : half_eighths);
    }

    if (codepoint <= lower_full) {
      return slab(cell, Side::bottom, codepoint - Symbol::first_block);
    }

    if (codepoint >= left_first && codepoint < right_half) {
      return slab(cell, Side::left, right_half - codepoint);
    }

    if (codepoint == right_half || codepoint == right_eighth) {
      return slab(cell, Side::right, codepoint == right_eighth ? 1 : half_eighths);
    }

    if (codepoint >= first_shade && codepoint <= last_shade) {
      constexpr float quarter_coverage = 0.25F;
      Paint result{static_cast<float>(codepoint - first_shade + 1) * quarter_coverage};
      result.push({.width = cell.width, .height = cell.height});

      return result;
    }

    constexpr std::uint32_t first_quadrant = 0x2596;
    constexpr std::array<std::uint8_t, 10> quadrants{
        lower_left,
        lower_right,
        upper_left,
        upper_left | lower_left | lower_right,
        upper_left | lower_right,
        upper_left | upper_right | lower_left,
        upper_left | upper_right | lower_right,
        upper_right,
        upper_right | lower_left,
        upper_right | lower_left | lower_right,
    };

    return quadrantInk(cell, quadrants[codepoint - first_quadrant]);
  }

  enum class Side : std::uint8_t {
    top,
    bottom,
    left,
    right,
  };

  static constexpr unsigned full_eighths = 8;
  static constexpr unsigned half_eighths = full_eighths / 2;

  [[nodiscard]] static float split(float extent, unsigned eighths) noexcept {
    return eighths >= full_eighths ? extent : std::round(extent * static_cast<float>(eighths) / full_eighths);
  }

  [[nodiscard]] static Paint slab(Rect cell, Side side, unsigned eighths) {
    Paint result;
    switch (side) {
    case Side::top:
      result.push({.width = cell.width, .height = split(cell.height, eighths)});
      break;
    case Side::bottom: {
      const auto top = split(cell.height, full_eighths - eighths);
      result.push({.y = top, .width = cell.width, .height = cell.height - top});
      break;
    }
    case Side::left:
      result.push({.width = split(cell.width, eighths), .height = cell.height});
      break;
    case Side::right: {
      const auto left = split(cell.width, full_eighths - eighths);
      result.push({.x = left, .width = cell.width - left, .height = cell.height});
      break;
    }
    }

    return result;
  }

  [[nodiscard]] static Paint quadrantInk(Rect cell, std::uint8_t mask) {
    const auto middle_x = split(cell.width, half_eighths);
    const auto middle_y = split(cell.height, half_eighths);
    const std::array<float, 2> tops{0, middle_y};
    const std::array<float, 2> bottoms{middle_y, cell.height};
    Paint result;
    for (std::size_t row = 0; row < tops.size(); ++row) {
      const auto left = (mask & (upper_left << (2 * row))) != 0;
      const auto right = (mask & (upper_right << (2 * row))) != 0;
      if (!left && !right) {
        continue;
      }

      const auto x = left ? 0 : middle_x;
      const auto right_edge = right ? cell.width : middle_x;
      result.appendMerged({.x = x, .y = tops[row], .width = right_edge - x, .height = bottoms[row] - tops[row]});
    }

    return result;
  }
};

}
