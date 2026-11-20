module telar.runtime.terminal.control.checksum;

import telar.ghostty.vt;
import telar.runtime.terminal.ghostty;
import telar.base.ds;

namespace telar::runtime::control {

  namespace {

    // What XTCHECKSUM counts for a character it cannot keep in 8 bits.
    constexpr std::uint16_t escape_value = 0x1b;

    // The value of a character xterm keeps in 8 bits: printable ASCII, C1 and printable Latin-1
    // count without their high bit, DEL and 0xff count nothing, and the rest count as ESC.
    constexpr std::uint16_t narrowValue(std::uint32_t codepoint) noexcept {
      constexpr std::uint32_t delete_character = 0x7f;
      constexpr std::uint32_t latin1_last = 0xff;
      constexpr std::uint32_t c1_first = 0x80;
      constexpr std::uint32_t c1_last = 0x9f;
      constexpr std::uint32_t latin1_printable_first = 0xa1;
      constexpr std::uint32_t latin1_printable_last = 0xfe;
      constexpr std::uint32_t seven_bits = 0x7f;

      if (codepoint == delete_character || codepoint == latin1_last) {
        return 0;
      }

      if ((codepoint >= ' ' && codepoint <= '~') || (codepoint >= c1_first && codepoint <= c1_last) || (codepoint >= latin1_printable_first && codepoint <= latin1_printable_last)) {
        return static_cast<std::uint16_t>(codepoint & seven_bits);
      }

      return escape_value;
    }

    // The value a cell's character adds, or none for a cell the traversal skips. A blank traversal
    // counts cells without text as spaces.
    template <bool Full, bool Blank>
    [[gnu::always_inline]] inline ds::Option<std::uint16_t> characterValue(GhosttyCellWide wide, bool has_text, std::uint32_t codepoint) noexcept {
      if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
        if (Full) {
          return ds::none;
        }

        return escape_value;
      }

      if (!has_text) {
        if (!Blank) {
          return ds::none;
        }

        return static_cast<std::uint16_t>(' ');
      }

      if (Full) {
        return static_cast<std::uint16_t>(codepoint);
      }

      return narrowValue(codepoint);
    }

    // The attribute bits XTCHECKSUM adds for a styled cell, as xterm's.
    std::uint16_t styleAttributes(const GhosttyStyle& style) noexcept {
      constexpr unsigned invisible = 8;
      constexpr unsigned underline = 16;
      constexpr unsigned inverse = 32;
      constexpr unsigned blink = 64;
      constexpr unsigned bold = 128;

      return static_cast<std::uint16_t>((style.invisible ? invisible : 0U) + (style.underline != 0 ? underline : 0U) + (style.inverse ? inverse : 0U) + (style.blink ? blink : 0U) + (style.bold ? bold : 0U));
    }

    // A cell's value with the attributes XTCHECKSUM counts: its protection and its style's bits.
    constexpr std::uint16_t attributedValue(std::uint16_t value, bool protected_cell, std::uint16_t style_attributes) noexcept {
      constexpr unsigned protected_bit = 4;

      return static_cast<std::uint16_t>(value + (protected_cell ? protected_bit : 0U) + style_attributes);
    }

    // A cell's column and the id of its style, 0 for none.
    struct StyledCell {
      std::size_t column;
      GhosttyStyleId id;
    };

    // The style of the cells a row has met so far, looked up once per run of cells that share it.
    struct RowStyle {
      std::uint16_t attributes = 0;
      bool extended = false;
      GhosttyStyleId id = 0;

      void update(GhosttyGridRef& reference, StyledCell cell) {
        if (cell.id == 0 || cell.id == id) {
          return;
        }

        reference.x = static_cast<std::uint16_t>(cell.column);
        auto style = ghosttySized<GhosttyStyle>();

        checkGhostty(ghostty_grid_ref_style(&reference, &style));
        attributes = styleAttributes(style);
        extended = style.faint || style.italic || style.strikethrough || style.underline == 2;
        id = cell.id;
      }

      // The attribute bits of a cell with this style id.
      [[nodiscard]] std::uint16_t bitsOf(GhosttyStyleId style_id) const noexcept {
        return style_id != 0 ? attributes : 0;
      }

      // Whether a cell with this style id counts where trimming skips a blank.
      [[nodiscard]] bool extends(GhosttyStyleId style_id) const noexcept {
        return style_id != 0 && extended;
      }
    };

    // What a cell holds as text: its content tag, and its codepoint, 0 without text content.
    struct CellText {
      GhosttyCellContentTag content;
      std::uint32_t codepoint;
      bool text_content;
    };

    [[gnu::always_inline]] inline CellText cellText(GhosttyCell cell) noexcept {
      const auto content = static_cast<GhosttyCellContentTag>(cell_layout::content_tag(cell));
      const bool text_content = content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME;

      return {.content = content, .codepoint = text_content ? static_cast<std::uint32_t>(cell_layout::codepoint(cell)) : 0, .text_content = text_content};
    }

    void checkRowStorage(const GhosttyCellsView& view) {
      if (view.ptr == nullptr && view.len != 0) {
        throw std::logic_error{"Checksum row view has no storage"};
      }
    }

    // The columns of a row's grapheme clusters, gathered for one batched lookup.
    template <std::size_t Capacity>
    struct GraphemeColumns { // NOLINT(cppcoreguidelines-pro-type-member-init): a column is written before its batch reads it, so zeroing the batch for every row is work no read needs
      ds::Array<std::uint16_t, Capacity> columns;
      std::size_t count = 0;

      // True when the batch is full.
      bool push(std::size_t column) noexcept {
        columns.atMut(count++) = static_cast<std::uint16_t>(column);
        return count == columns.size();
      }

      [[nodiscard]] std::span<const std::uint16_t> view() const noexcept {
        return columns.view().first(count);
      }
    };

  }

  Checksum::Checksum(ConcurrentMemory& memory)
      : graphemes_(memory) {}

  void Checksum::discard() noexcept { // NOLINT(bugprone-exception-escape): the empty Vec shares the old one's memory, so the move hands storage over without allocating
    graphemes_ = ds::Vec<std::uint32_t, ConcurrentMemory>{graphemes_.memory()};
  }

  // Defined here, beside accumulate, so that this unit instantiates every specialization it names.
  const ds::Array<Checksum::Accumulator, 16> Checksum::accumulators = []<std::size_t... Index>(std::index_sequence<Index...>) noexcept {
    return ds::Array<Accumulator, sizeof...(Index)>{&Checksum::accumulate<static_cast<unsigned>(Index << 1U)>...};
  }(std::make_index_sequence<16>{});

  std::uint16_t Checksum::compute(const VtState& state, const Parameters& request) {
    const auto size = state.size();
    if (size.cols == 0 || size.rows == 0) {
      return 0;
    }

    // Where an edge falls along one axis: its default, the margin origin mode adds, and the screen's extent.
    struct Axis {
      unsigned fallback;
      unsigned offset;
      unsigned maximum;
    };

    const bool origin = state.mode(origin_mode);
    const auto margins = state.margins();
    const auto coordinate = [&](unsigned index, Axis axis) {
      const auto value = index < request.count && request.values[index] != 0 ? request.values[index] : axis.fallback;

      return static_cast<std::uint16_t>(std::clamp(value + axis.offset, 1U, axis.maximum) - 1);
    };

    const auto top = coordinate(2, {.fallback = 1, .offset = origin ? margins.top : 0U, .maximum = size.rows});
    const auto left = coordinate(3, {.fallback = 1, .offset = origin ? margins.left : 0U, .maximum = size.cols});
    const auto bottom = coordinate(4, {.fallback = size.rows, .offset = origin ? margins.top : 0U, .maximum = size.rows});
    const auto right = coordinate(5, {.fallback = size.cols, .offset = origin ? margins.left : 0U, .maximum = size.cols});
    if (top > bottom || left > right) {
      return 0;
    }

    const Rectangle rectangle{.top = top, .left = left, .bottom = bottom, .right = right};
    const auto selected_flags = flags;
    const auto sum = (this->*accumulators[(selected_flags >> 1U) & (accumulators.size() - 1)])(state, rectangle);

    return (selected_flags & static_cast<unsigned>(ChecksumFlag::positive)) != 0 ? sum : static_cast<std::uint16_t>(0U - sum);
  }

  template <unsigned SelectedFlags>
  std::uint16_t Checksum::accumulate(const VtState& state, Rectangle rectangle) {
    constexpr bool no_trim = (SelectedFlags & static_cast<unsigned>(ChecksumFlag::no_trim)) != 0;
    std::uint16_t sum = 0;
    bool first = true;

    for (unsigned row = rectangle.top; row <= rectangle.bottom; ++row) {
      auto reference = state.reference({.column = 0, .row = static_cast<std::uint16_t>(row)});
      if (reference) {
        sum = static_cast<std::uint16_t>(sum + accumulateRow<SelectedFlags>(reference.getMut(), rectangle, first));
      }

      if (!no_trim) {
        first = false;
      }
    }

    return sum;
  }

  template <unsigned SelectedFlags>
  std::uint16_t Checksum::accumulateRow(GhosttyGridRef& reference, Rectangle rectangle, bool& first) {
    constexpr auto selected = [](ChecksumFlag flag) {
      return (SelectedFlags & static_cast<unsigned>(flag)) != 0;
    };

    constexpr bool no_trim = selected(ChecksumFlag::no_trim);
    constexpr bool no_attributes = selected(ChecksumFlag::no_attributes);
    constexpr bool full = selected(ChecksumFlag::full);
    constexpr bool undrawn = selected(ChecksumFlag::undrawn);
    constexpr bool needs_style = !no_attributes || !no_trim;
    constexpr bool graphemes = no_trim && !full;
    GhosttyCellsView view{};

    checkGhostty(ghostty_grid_ref_cells(&reference, &view));
    checkRowStorage(view);
    // Ghostty hands the row's cells as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
    const std::span<const GhosttyCell> cells{view.ptr, view.len};
#pragma clang unsafe_buffer_usage end
    const auto begin = std::min<std::size_t>(rectangle.left, cells.size());
    const auto end = std::min<std::size_t>(rectangle.right + 1, cells.size());
    constexpr bool blank = no_trim || undrawn;
    GraphemeColumns<maximum_batch_columns> batch;
    RowStyle style;
    std::uint16_t sum = 0;

    for (std::size_t column = begin; column < end; ++column) {
      const auto cell = cells[column];
      if (cell == 0 && !blank) {
        continue;
      }

      const auto text = cellText(cell);
      const bool has_text = text.codepoint != 0;

      if (graphemes && has_text && text.content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME && batch.push(column)) {
        sum = static_cast<std::uint16_t>(sum + combiningBatch(reference, batch.columns));
        batch.count = 0;
      }

      if (graphemes && text.text_content && text.codepoint >= ' ' && text.codepoint <= '~' && (cell & plainCellMask<no_attributes>()) == 0) {
        sum = static_cast<std::uint16_t>(sum + text.codepoint);
        continue;
      }

      auto value = characterValue<full, blank>(static_cast<GhosttyCellWide>(cell_layout::wide(cell)), has_text, text.codepoint);
      if (!value) {
        continue;
      }

      const auto style_id = static_cast<GhosttyStyleId>(cell_layout::style_id(cell));

      if (needs_style) {
        style.update(reference, {.column = column, .id = style_id});
      }

      if (!no_attributes) {
        value = attributedValue(*value, cell_layout::protected_cell(cell) != 0, style.bitsOf(style_id));
      }

      if (no_trim || first || *value != ' ' || style.extends(style_id)) {
        sum = static_cast<std::uint16_t>(sum + *value);
      }

      first = no_trim;
    }

    // The batch reads a single column as combining() does.
    if (graphemes && batch.count != 0) {
      sum = static_cast<std::uint16_t>(sum + combiningBatch(reference, batch.view()));
    }

    return sum;
  }

  std::uint16_t Checksum::combiningBatch(GhosttyGridRef reference, std::span<const std::uint16_t> columns) {
    ds::Array<std::uint32_t, batch_points> points; // NOLINT(cppcoreguidelines-pro-type-member-init): ghostty writes the points a batch reports before they are read, so zeroing 1 KiB per batch is work no read needs
    std::uint16_t sum = 0;

    while (!columns.empty()) {
      if (columns.size() == 1) {
        reference.x = columns.front();
        return static_cast<std::uint16_t>(sum + combining(reference));
      }

      GhosttyGraphemeBatch batch{
          .points = points.dataMut(),
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

  std::uint16_t Checksum::combining(const GhosttyGridRef& reference) {
    constexpr std::size_t inline_grapheme_points = 16;
    ds::Array<std::uint32_t, inline_grapheme_points> inline_points; // NOLINT(cppcoreguidelines-pro-type-member-init): ghostty writes the points it reports before they are read
    std::size_t count = 0;
    auto status = ghostty_grid_ref_graphemes(&reference, inline_points.dataMut(), inline_points.size(), &count);
    std::span<const std::uint32_t> points = std::span<const std::uint32_t>{inline_points}.first(std::min(count, inline_points.size()));

    if (status == GHOSTTY_OUT_OF_SPACE) {
      if (count > maximum_grapheme_points) {
        throw std::length_error{"Checksum grapheme exceeds its memory limit"};
      }

      graphemes_.resize(count);
      status = ghostty_grid_ref_graphemes(&reference, graphemes_.dataMut(), graphemes_.size(), &count);
      points = std::span<const std::uint32_t>{graphemes_}.first(count);
    }

    checkGhostty(status);

    std::uint16_t result = 0;

    for (std::size_t index = 1; index < points.size(); ++index) {
      result = static_cast<std::uint16_t>(result + points[index]);
    }

    return result;
  }

}
