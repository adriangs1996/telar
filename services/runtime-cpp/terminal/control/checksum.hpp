#pragma once

#include "parameters.hpp"
#include "vt_state.hpp"
#include "../../memory/allocator.hpp"

namespace telar::runtime::control {

enum class ChecksumFlag : unsigned {
  positive = 1,
  no_attributes = 2,
  no_trim = 4,
  undrawn = 8,
  full = 16
};

template <Allocator Memory>
class Checksum {
public:
  explicit Checksum(Memory &memory) : graphemes_(AllocatorRef<std::uint32_t, Memory>{memory}) {}

  std::uint16_t compute(const VtState &state, const Parameters &request) {
    const auto size = state.size();
    if (size.cols == 0 || size.rows == 0) {
      return 0;
    }

    const bool origin = state.mode(origin_mode);
    const auto margins = state.margins();
    const auto coordinate = [&](unsigned index, unsigned fallback, unsigned offset, unsigned maximum) {
      const auto value = index < request.count && request.values[index] != 0 ? request.values[index] : fallback;
      return static_cast<std::uint16_t>(std::clamp(value + offset, 1u, maximum) - 1);
    };
    const auto top = coordinate(2, 1, origin ? margins.top : 0, size.rows);
    const auto left = coordinate(3, 1, origin ? margins.left : 0, size.cols);
    const auto bottom = coordinate(4, size.rows, origin ? margins.top : 0, size.rows);
    const auto right = coordinate(5, size.cols, origin ? margins.left : 0, size.cols);
    if (top > bottom || left > right) {
      return 0;
    }

    std::uint16_t sum = 0;
    bool first = true;
    for (unsigned row = top; row <= bottom; ++row) {
      for (unsigned column = left; column <= right; ++column) {
        const auto reference = state.reference({static_cast<std::uint16_t>(column), static_cast<std::uint16_t>(row)});
        if (!reference) {
          continue;
        }

        GhosttyCell cell = 0;
        checkGhostty(ghostty_grid_ref_cell(&*reference, &cell));
        bool has_text = false;
        bool protected_cell = false;
        std::uint32_t codepoint = 0;
        GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
        const GhosttyCellData keys[]{GHOSTTY_CELL_DATA_HAS_TEXT, GHOSTTY_CELL_DATA_PROTECTED, GHOSTTY_CELL_DATA_CODEPOINT, GHOSTTY_CELL_DATA_WIDE};
        void *values[]{&has_text, &protected_cell, &codepoint, &wide};
        checkGhostty(ghostty_cell_get_multi(cell, std::size(keys), keys, values, nullptr));

        std::uint16_t value = 0;
        if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
          if (has(ChecksumFlag::full)) {
            continue;
          }
          value = escape_value;
        } else if (!has_text) {
          if (!has(ChecksumFlag::no_trim) && !has(ChecksumFlag::undrawn)) {
            continue;
          }
          value = ' ';
        } else if (has(ChecksumFlag::full)) {
          value = static_cast<std::uint16_t>(codepoint);
        } else if (codepoint == 0x7f || codepoint == 0xff) {
          value = 0;
        } else if ((codepoint >= 0x20 && codepoint <= 0x7e) || (codepoint >= 0x80 && codepoint <= 0x9f) || (codepoint >= 0xa1 && codepoint <= 0xfe)) {
          value = static_cast<std::uint16_t>(codepoint & 0x7f);
        } else {
          value = escape_value;
        }

        auto style = ghosttySized<GhosttyStyle>();
        checkGhostty(ghostty_grid_ref_style(&*reference, &style));
        if (!has(ChecksumFlag::no_attributes)) {
          value = static_cast<std::uint16_t>(value + (protected_cell ? 4 : 0) + (style.invisible ? 8 : 0) + (style.underline != 0 ? 16 : 0) + (style.inverse ? 32 : 0) + (style.blink ? 64 : 0) + (style.bold ? 128 : 0));
        }

        const bool extended = style.faint || style.italic || style.strikethrough || style.underline == 2;
        if (has(ChecksumFlag::no_trim)) {
          sum = static_cast<std::uint16_t>(sum + value);
          if (!has(ChecksumFlag::full) && has_text) {
            sum = static_cast<std::uint16_t>(sum + combining(*reference));
          }
        } else if (first || value != ' ' || extended) {
          sum = static_cast<std::uint16_t>(sum + value);
        }
        first = has(ChecksumFlag::no_trim);
      }
      if (!has(ChecksumFlag::no_trim)) {
        first = false;
      }
    }
    return has(ChecksumFlag::positive) ? sum : static_cast<std::uint16_t>(0u - sum);
  }

  unsigned flags = 0;

private:
  bool has(ChecksumFlag flag) const noexcept {
    return (flags & static_cast<unsigned>(flag)) != 0;
  }

  std::uint16_t combining(const GhosttyGridRef &reference) {
    std::array<std::uint32_t, 16> inline_points;
    std::size_t count = 0;
    auto status = ghostty_grid_ref_graphemes(&reference, inline_points.data(), inline_points.size(), &count);
    std::span<const std::uint32_t> points = std::span<const std::uint32_t>{inline_points}.first(std::min(count, inline_points.size()));
    if (status == GHOSTTY_OUT_OF_SPACE) {
      if (count > maximum_grapheme_points) {
        throw std::length_error{"Checksum grapheme exceeds its memory limit"};
      }
      graphemes_.resize(count);
      status = ghostty_grid_ref_graphemes(&reference, graphemes_.data(), graphemes_.size(), &count);
      points = std::span<const std::uint32_t>{graphemes_}.first(count);
    }
    checkGhostty(status);

    std::uint16_t result = 0;
    for (std::size_t index = 1; index < points.size(); ++index) {
      result = static_cast<std::uint16_t>(result + points[index]);
    }
    return result;
  }

  static constexpr unsigned origin_mode = 6;
  static constexpr std::uint16_t escape_value = 0x1b;
  static constexpr std::size_t maximum_grapheme_points = UINT16_MAX;
  Vector<std::uint32_t, Memory> graphemes_;
};

}
