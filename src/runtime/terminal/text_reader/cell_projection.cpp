module telar.runtime.terminal.text_reader;

import std;

import telar.ghostty.vt;
import telar.wire.vocabulary;
import telar.runtime.terminal.control;
import telar.runtime.terminal.grid;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // UTF-8's encoding: the first codepoint each sequence length cannot hold, the lead byte of each
    // length, and the six payload bits of each continuation byte.
    constexpr std::uint32_t one_byte_end = 0x80U;
    constexpr std::uint32_t two_byte_end = 0x800U;
    constexpr std::uint32_t three_byte_end = 0x10000U;
    constexpr std::uint32_t two_byte_lead = 0xc0U;
    constexpr std::uint32_t three_byte_lead = 0xe0U;
    constexpr std::uint32_t four_byte_lead = 0xf0U;
    constexpr std::uint32_t continuation_lead = 0x80U;
    constexpr std::uint32_t continuation_mask = 0x3fU;
    constexpr unsigned continuation_bits = 6;

    CellColor rgbColor(GhosttyColorRgb color) noexcept {
      return CellColor{.kind = CellColor::Kind::rgb, .channels = {color.r, color.g, color.b}};
    }

    // The continuation byte of the six bits `shift` bits up the codepoint.
    constexpr Byte continuation(std::uint32_t codepoint, unsigned shift) noexcept {
      return static_cast<Byte>(continuation_lead | ((codepoint >> shift) & continuation_mask));
    }

    // Writes up to four bytes; the caller leaves that room in `output`.
    Byte encodeCodepoint(std::uint32_t codepoint, std::span<Byte> output) noexcept {
      if (codepoint < one_byte_end) {
        output[0] = codepoint == 0 ? ' ' : static_cast<Byte>(codepoint);
        return 1;
      }

      if (codepoint < two_byte_end) {
        output[0] = static_cast<Byte>(two_byte_lead | (codepoint >> continuation_bits));
        output[1] = continuation(codepoint, 0);
        return 2;
      }

      if (codepoint < three_byte_end) {
        output[0] = static_cast<Byte>(three_byte_lead | (codepoint >> (2 * continuation_bits)));
        output[1] = continuation(codepoint, continuation_bits);
        output[2] = continuation(codepoint, 0);
        return 3;
      }

      output[0] = static_cast<Byte>(four_byte_lead | (codepoint >> (3 * continuation_bits)));
      output[1] = continuation(codepoint, 2 * continuation_bits);
      output[2] = continuation(codepoint, continuation_bits);
      output[3] = continuation(codepoint, 0);
      return 4;
    }

  }

  bool CellProjection::updateColors(GhosttyTerminal terminal, GhosttyRenderState render_state) {
    checkGhostty(ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors_));
    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_OVERRIDES, palette_overrides_.dataMut()));

    GhosttyColorRgb foreground{};
    GhosttyColorRgb background{};
    const auto foreground_result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_OVERRIDE, &foreground);
    const auto background_result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_OVERRIDE, &background);
    GhosttyTerminalModeConfig reverse{.mode = GHOSTTY_MODE_REVERSE_COLORS, .value = false};

    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &reverse));

    const auto previous = default_style_;

    default_style_ = {};
    if (reverse.value || foreground_result == GHOSTTY_SUCCESS) {
      default_style_.foreground = rgbColor(colors_.foreground);
    }

    if (reverse.value || background_result == GHOSTTY_SUCCESS) {
      default_style_.background = rgbColor(colors_.background);
    }

    return default_style_ != previous;
  }

  CellColor CellProjection::paletteColor(Byte index) const noexcept {
    if (palette_overrides_[index] != 0) {
      return rgbColor(std::span{colors_.palette}[index]);
    }

    return CellColor{.kind = CellColor::Kind::indexed, .channels = {index, 0, 0}};
  }

  CellColor CellProjection::resolveColor(const GhosttyStyleColor& color, CellColor fallback) const noexcept {
    switch (color.tag) {
    case GHOSTTY_STYLE_COLOR_RGB:
      return rgbColor(color.value.rgb);
    case GHOSTTY_STYLE_COLOR_PALETTE:
      return paletteColor(color.value.palette);
    case GHOSTTY_STYLE_COLOR_NONE:
    case decltype(color.tag)::GHOSTTY_STYLE_COLOR_TAG_MAX_VALUE:
      return fallback;
    }

    // A tag outside the enum, as the old default.
    return fallback;
  }

  CellStyle CellProjection::translateStyle(const GhosttyStyle& style) const noexcept {
    CellStyle translated{
        .foreground = resolveColor(style.fg_color, default_style_.foreground),
        .background = resolveColor(style.bg_color, default_style_.background),
        .underline_color = resolveColor(style.underline_color, {}),
    };

    const auto flag = [&](bool enabled, CellAttribute attribute) {
      if (enabled) {
        translated.flags |= static_cast<std::uint16_t>(attribute);
      }
    };

    flag(style.bold, CellAttribute::bold);
    flag(style.italic, CellAttribute::italic);
    flag(style.faint, CellAttribute::faint);
    flag(style.blink, CellAttribute::blink);
    flag(style.inverse, CellAttribute::inverse);
    flag(style.invisible, CellAttribute::invisible);
    flag(style.strikethrough, CellAttribute::strikethrough);
    flag(style.overline, CellAttribute::overline);
    constexpr unsigned underline_shift = 8;

    translated.flags |= static_cast<std::uint16_t>(static_cast<unsigned>(style.underline) << underline_shift);
    return translated;
  }

  void CellProjection::writeGrapheme(GhosttyRenderStateRowCells cells, ScreenCell& destination) {
    constexpr std::size_t maximum_extra_codepoints = 15;
    ds::Array<std::uint32_t, maximum_extra_codepoints> storage; // NOLINT(cppcoreguidelines-pro-type-member-init): ghostty writes the codepoints it reports, and zeroing them would cost every grapheme cell
    GhosttyCodepointsBuffer codepoints{.ptr = storage.dataMut(), .cap = storage.size(), .len = 0};

    checkGhostty(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_EXTRA, &codepoints));
    // Ghostty fills `storage` through codepoints.ptr.
    for (const auto codepoint : storage.view().first(std::min(codepoints.len, storage.size()))) {
      constexpr std::size_t maximum_utf8_bytes = 4;
      if (destination.text.size() - destination.length < maximum_utf8_bytes) {
        break;
      }

      destination.length += encodeCodepoint(codepoint, destination.text.viewMut().subspan(destination.length));
    }
  }

  void CellProjection::copyRow(GhosttyRenderStateRowIterator row, GhosttyRenderStateRowCells cells, std::span<ScreenCell> destination) const {
    GhosttyCellsView source{};

    checkGhostty(ghostty_render_state_row_get(row, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &source));
    checkGhostty(ghostty_render_state_row_get(row, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, static_cast<void*>(&cells)));

    GhosttyStyleId previous_style_id = 0;
    CellStyle previous_style = default_style_;
    // Ghostty hands the row's cells as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
    const std::span<const GhosttyCell> raw_cells{source.ptr, source.len};
#pragma clang unsafe_buffer_usage end
    const auto count = std::min(destination.size(), raw_cells.size());

    for (std::size_t column = 0; column < count; ++column) {
      const GhosttyCell raw = raw_cells[column];
      const auto style_id = static_cast<GhosttyStyleId>(cell_layout::style_id(raw));
      const auto width = static_cast<GhosttyCellWide>(cell_layout::wide(raw));
      ScreenCell cell{};

      if (style_id != 0 && style_id != previous_style_id) {
        checkGhostty(ghostty_render_state_row_cells_select(cells, static_cast<std::uint16_t>(column)));
        auto style = ghosttySized<GhosttyStyle>();

        checkGhostty(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));
        previous_style = translateStyle(style);
        previous_style_id = style_id;
      }

      cell.style = style_id == 0 ? default_style_ : previous_style;
      if (width == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
        cell.width = CellWidth::continuation;
        cell.length = 0;
        cell.text = {};
        destination[column] = cell;
        continue;
      }

      if (width == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
        destination[column] = cell;
        continue;
      }

      cell.width = width == GHOSTTY_CELL_WIDE_WIDE ? CellWidth::wide : CellWidth::single;
      projectContent(raw, cells, column, cell);
      destination[column] = cell;
    }
  }

  void CellProjection::projectContent(GhosttyCell raw, GhosttyRenderStateRowCells cells, std::size_t column, ScreenCell& cell) const {
    switch (static_cast<GhosttyCellContentTag>(cell_layout::content_tag(raw))) {
    case GHOSTTY_CELL_CONTENT_CODEPOINT:
      cell.length = encodeCodepoint(static_cast<std::uint32_t>(cell_layout::codepoint(raw)), cell.text.viewMut());
      return;
    case GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME:
      cell.length = encodeCodepoint(static_cast<std::uint32_t>(cell_layout::codepoint(raw)), cell.text.viewMut());
      checkGhostty(ghostty_render_state_row_cells_select(cells, static_cast<std::uint16_t>(column)));
      writeGrapheme(cells, cell);
      return;
    case GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE:
      cell.style = {};
      cell.style.background = paletteColor(static_cast<Byte>(cell_layout::index(raw)));
      return;
    case GHOSTTY_CELL_CONTENT_BG_COLOR_RGB:
      cell.style = {};
      cell.style.background = rgbColor(GhosttyColorRgb{
          .r = static_cast<Byte>(cell_layout::r(raw)),
          .g = static_cast<Byte>(cell_layout::g(raw)),
          .b = static_cast<Byte>(cell_layout::b(raw)),
      });

      return;
    case GhosttyCellContentTag::GHOSTTY_CELL_CONTENT_TAG_MAX_VALUE:
      break;
    }

    // A tag no case names, as the old default.
    throw TerminalError{GHOSTTY_INVALID_VALUE};
  }

}
