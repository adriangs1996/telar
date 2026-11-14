module;
#include <ghostty/vt.h>

module telar.runtime.terminal.control.checksum;

namespace telar::runtime::control {

  template <Allocator Memory>
  Checksum<Memory>::Checksum(Memory& memory)
      : graphemes_(AllocatorRef<std::uint32_t, Memory>{memory}) {}

  template <Allocator Memory>
  void Checksum<Memory>::discard() noexcept {
    Vector<std::uint32_t, Memory>{graphemes_.get_allocator()}.swap(graphemes_);
  }

  // Defined here, beside accumulate, so that this unit instantiates every specialization it names.
  template <Allocator Memory>
  const std::array<typename Checksum<Memory>::Accumulator, 16> Checksum<Memory>::accumulators = []<std::size_t... Index>(std::index_sequence<Index...>) {
    return std::array<Accumulator, sizeof...(Index)>{&Checksum::template accumulate<static_cast<unsigned>(Index << 1)>...};
  }(std::make_index_sequence<16>{});

  template <Allocator Memory>
  std::uint16_t Checksum<Memory>::compute(const VtState& state, const Parameters& request) {
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

    const Rectangle rectangle{top, left, bottom, right};
    const auto selected_flags = flags;
    const auto sum = (this->*accumulators[(selected_flags >> 1) & (accumulators.size() - 1)])(state, rectangle);

    return (selected_flags & static_cast<unsigned>(ChecksumFlag::positive)) != 0 ? sum : static_cast<std::uint16_t>(0u - sum);
  }

  template <Allocator Memory>
  template <unsigned SelectedFlags>
  std::uint16_t Checksum<Memory>::accumulate(const VtState& state, Rectangle rectangle) {
    constexpr auto selected = [](ChecksumFlag flag) {
      return (SelectedFlags & static_cast<unsigned>(flag)) != 0;
    };

    constexpr bool no_trim = selected(ChecksumFlag::no_trim);
    constexpr bool no_attributes = selected(ChecksumFlag::no_attributes);
    constexpr bool full = selected(ChecksumFlag::full);
    constexpr bool undrawn = selected(ChecksumFlag::undrawn);
    constexpr bool needs_style = !no_attributes || !no_trim;
    std::uint16_t sum = 0;
    bool first = true;

    for (unsigned row = rectangle.top; row <= rectangle.bottom; ++row) {
      auto reference = state.reference({0, static_cast<std::uint16_t>(row)});
      if (!reference) {
        if (!no_trim) {
          first = false;
        }

        continue;
      }

      GhosttyCellsView cells{};

      checkGhostty(ghostty_grid_ref_cells(&*reference, &cells));
      if (cells.ptr == nullptr && cells.len != 0) {
        throw std::logic_error{"Checksum row view has no storage"};
      }

      const auto begin = std::min<std::size_t>(rectangle.left, cells.len);
      const auto end = std::min<std::size_t>(rectangle.right + 1, cells.len);
      std::array<std::uint16_t, maximum_batch_columns> grapheme_columns;
      std::size_t grapheme_count = 0;
      std::uint16_t previous_attributes = 0;
      bool previous_extended = false;
      GhosttyStyleId previous_style_id = 0;

      for (std::size_t column = begin; column < end; ++column) {
        const auto cell = cells.ptr[column];
        if (cell == 0 && !no_trim && !undrawn) {
          continue;
        }

        const auto content = static_cast<GhosttyCellContentTag>(cell_layout::content_tag(cell));
        const bool text_content = content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME;
        const auto codepoint = text_content ? static_cast<std::uint32_t>(cell_layout::codepoint(cell)) : 0;
        const bool has_text = codepoint != 0;
        const bool protected_cell = cell_layout::protected_cell(cell) != 0;
        const auto wide = static_cast<GhosttyCellWide>(cell_layout::wide(cell));

        if (no_trim && !full && has_text && content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME) {
          grapheme_columns[grapheme_count++] = static_cast<std::uint16_t>(column);
          if (grapheme_count == grapheme_columns.size()) {
            sum = static_cast<std::uint16_t>(sum + combiningBatch(*reference, grapheme_columns));
            grapheme_count = 0;
          }
        }

        if (no_trim && !full && text_content && codepoint >= ' ' && codepoint <= '~' && (cell & plainCellMask<no_attributes>()) == 0) {
          sum = static_cast<std::uint16_t>(sum + codepoint);
          continue;
        }

        std::uint16_t value = 0;

        if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
          if (full) {
            continue;
          }

          value = escape_value;
        } else if (!has_text) {
          if (!no_trim && !undrawn) {
            continue;
          }

          value = ' ';
        } else if (full) {
          value = static_cast<std::uint16_t>(codepoint);
        } else if (codepoint == 0x7f || codepoint == 0xff) {
          value = 0;
        } else if ((codepoint >= 0x20 && codepoint <= 0x7e) || (codepoint >= 0x80 && codepoint <= 0x9f) || (codepoint >= 0xa1 && codepoint <= 0xfe)) {
          value = static_cast<std::uint16_t>(codepoint & 0x7f);
        } else {
          value = escape_value;
        }

        const auto style_id = static_cast<GhosttyStyleId>(cell_layout::style_id(cell));
        if (needs_style && style_id != 0 && style_id != previous_style_id) {
          reference->x = static_cast<std::uint16_t>(column);
          auto style = ghosttySized<GhosttyStyle>();

          checkGhostty(ghostty_grid_ref_style(&*reference, &style));
          previous_attributes = static_cast<std::uint16_t>((style.invisible ? 8 : 0) + (style.underline != 0 ? 16 : 0) + (style.inverse ? 32 : 0) + (style.blink ? 64 : 0) + (style.bold ? 128 : 0));
          previous_extended = style.faint || style.italic || style.strikethrough || style.underline == 2;
          previous_style_id = style_id;
        }

        if (!no_attributes) {
          value = static_cast<std::uint16_t>(value + (protected_cell ? 4 : 0) + (style_id != 0 ? previous_attributes : 0));
        }

        const bool extended = style_id != 0 && previous_extended;

        if (no_trim) {
          sum = static_cast<std::uint16_t>(sum + value);
        } else if (first || value != ' ' || extended) {
          sum = static_cast<std::uint16_t>(sum + value);
        }

        first = no_trim;
      }

      if (no_trim && !full && grapheme_count != 0) {
        if (grapheme_count == 1) {
          reference->x = grapheme_columns.front();
          sum = static_cast<std::uint16_t>(sum + combining(*reference));
        } else {
          sum = static_cast<std::uint16_t>(sum + combiningBatch(*reference, std::span{grapheme_columns}.first(grapheme_count)));
        }
      }

      if (!no_trim) {
        first = false;
      }
    }

    return sum;
  }

  template <Allocator Memory>
  std::uint16_t Checksum<Memory>::combiningBatch(GhosttyGridRef reference, std::span<const std::uint16_t> columns) {
    std::array<std::uint32_t, batch_points> points;
    std::uint16_t sum = 0;

    while (!columns.empty()) {
      if (columns.size() == 1) {
        reference.x = columns.front();
        return static_cast<std::uint16_t>(sum + combining(reference));
      }

      GhosttyGraphemeBatch batch{
          .points = points.data(),
          .capacity = points.size(),
          .length = 0,
          .consumed_columns = 0,
      };

      const auto status = ghostty_grid_ref_grapheme_batch(&reference, columns.data(), columns.size(), &batch);
      if (status != GHOSTTY_OUT_OF_SPACE) {
        checkGhostty(status);
      }

      if (batch.length > points.size() || batch.consumed_columns > columns.size() || (status == GHOSTTY_SUCCESS && batch.consumed_columns != columns.size()) || (batch.consumed_columns == 0 && batch.length != 0)) {
        throw std::logic_error{"Grapheme batch has invalid progress"};
      }

      for (const auto codepoint : std::span{points}.first(batch.length)) {
        sum = static_cast<std::uint16_t>(sum + codepoint);
      }

      if (batch.consumed_columns == 0) {
        for (const auto column : columns) {
          reference.x = column;
          sum = static_cast<std::uint16_t>(sum + combining(reference));
        }

        return sum;
      }

      columns = columns.subspan(batch.consumed_columns);
    }

    return sum;
  }

  template <Allocator Memory>
  std::uint16_t Checksum<Memory>::combining(const GhosttyGridRef& reference) {
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

  template class Checksum<telar::ConcurrentMemory>;

}
