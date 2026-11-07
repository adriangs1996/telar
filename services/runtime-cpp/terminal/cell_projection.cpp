module;
#include <exception>
#include <ghostty/vt.h>
#include <source_location>
#include <utility>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>
#include <concepts>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <span>
#include <string_view>
#include <type_traits>
#include <cstdio>
#include <optional>
#include <variant>
#include <bit>
#include <stdexcept>

#include "cell_layout.hpp"
#include <cstring>
#include <array>

module telar.runtime.terminal.text_reader;

import telar.base.diagnostics;
import telar.client.protocol;
import telar.runtime.terminal.control;



namespace telar::runtime {

static CellColor rgbColor(GhosttyColorRgb color) noexcept {
  return CellColor{.kind = CellColor::Kind::rgb,
                   .channels = {color.r, color.g, color.b}};
}

static Byte encodeCodepoint(std::uint32_t codepoint, Byte *output) noexcept {
  if (codepoint < 0x80) {
    output[0] = codepoint == 0 ? ' ' : static_cast<Byte>(codepoint);
    return 1;
  }

  if (codepoint < 0x800) {
    output[0] = static_cast<Byte>(0xc0 | (codepoint >> 6));
    output[1] = static_cast<Byte>(0x80 | (codepoint & 0x3f));
    return 2;
  }

  if (codepoint < 0x10000) {
    output[0] = static_cast<Byte>(0xe0 | (codepoint >> 12));
    output[1] = static_cast<Byte>(0x80 | ((codepoint >> 6) & 0x3f));
    output[2] = static_cast<Byte>(0x80 | (codepoint & 0x3f));
    return 3;
  }

  output[0] = static_cast<Byte>(0xf0 | (codepoint >> 18));
  output[1] = static_cast<Byte>(0x80 | ((codepoint >> 12) & 0x3f));
  output[2] = static_cast<Byte>(0x80 | ((codepoint >> 6) & 0x3f));
  output[3] = static_cast<Byte>(0x80 | (codepoint & 0x3f));
  return 4;
}

void CellProjection::updateColors(GhosttyTerminal terminal, GhosttyRenderState render_state) {
  checkGhostty(ghostty_render_state_get(render_state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors_));
  checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_OVERRIDES, palette_overrides_.data()));

  GhosttyColorRgb foreground{};
  GhosttyColorRgb background{};
  const auto foreground_result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_OVERRIDE, &foreground);
  const auto background_result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_OVERRIDE, &background);
  GhosttyTerminalModeConfig reverse{.mode = GHOSTTY_MODE_REVERSE_COLORS,
                                    .value = false};
  checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &reverse));

  default_style_ = {};
  if (reverse.value || foreground_result == GHOSTTY_SUCCESS) {
    default_style_.foreground = rgbColor(colors_.foreground);
  }

  if (reverse.value || background_result == GHOSTTY_SUCCESS) {
    default_style_.background = rgbColor(colors_.background);
  }
}

CellColor CellProjection::paletteColor(Byte index) const noexcept {
  if (palette_overrides_[index] != 0) {
    return rgbColor(colors_.palette[index]);
  }

  return CellColor{.kind = CellColor::Kind::indexed,
                   .channels = {index, 0, 0}};
}

CellColor CellProjection::resolveColor(const GhosttyStyleColor &color, CellColor fallback) const noexcept {
  switch (color.tag) {
  case GHOSTTY_STYLE_COLOR_RGB:
    return rgbColor(color.value.rgb);
  case GHOSTTY_STYLE_COLOR_PALETTE:
    return paletteColor(color.value.palette);
  default:
    return fallback;
  }
}

CellStyle CellProjection::translateStyle(const GhosttyStyle &style) const noexcept {
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
  translated.flags |= static_cast<std::uint16_t>(style.underline << underline_shift);
  return translated;
}

void CellProjection::writeGrapheme(GhosttyRenderStateRowCells cells, ScreenCell &destination) {
  constexpr std::size_t maximum_extra_codepoints = 15;
  std::array<std::uint32_t, maximum_extra_codepoints> storage;
  GhosttyCodepointsBuffer codepoints{.ptr = storage.data(),
                                     .cap = storage.size(),
                                     .len = 0};
  checkGhostty(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_EXTRA, &codepoints));
  for (const auto codepoint : std::span<const std::uint32_t>{codepoints.ptr, codepoints.len}) {
    constexpr std::size_t maximum_utf8_bytes = 4;
    if (destination.text.size() - destination.length < maximum_utf8_bytes) {
      break;
    }
    destination.length += encodeCodepoint(codepoint, destination.text.data() + destination.length);
  }
}

void CellProjection::copyRow(GhosttyRenderStateRowIterator row, GhosttyRenderStateRowCells cells, std::span<ScreenCell> destination) const {
  GhosttyCellsView source{};
  checkGhostty(ghostty_render_state_row_get(row, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &source));
  checkGhostty(ghostty_render_state_row_get(row, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells));

  GhosttyStyleId previous_style_id = 0;
  CellStyle previous_style = default_style_;
  const auto count = std::min(destination.size(), source.len);

  for (std::size_t column = 0; column < count; ++column) {
    const GhosttyCell raw = source.ptr[column];
    const auto style_id = static_cast<GhosttyStyleId>(cell_layout::style_id(raw));
    const auto width = static_cast<GhosttyCellWide>(cell_layout::wide(raw));
    const auto content = static_cast<GhosttyCellContentTag>(cell_layout::content_tag(raw));
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
    switch (content) {
    case GHOSTTY_CELL_CONTENT_CODEPOINT:
      cell.length = encodeCodepoint(static_cast<std::uint32_t>(cell_layout::codepoint(raw)), cell.text.data());
      break;
    case GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME:
      cell.length = encodeCodepoint(static_cast<std::uint32_t>(cell_layout::codepoint(raw)), cell.text.data());
      checkGhostty(ghostty_render_state_row_cells_select(cells, static_cast<std::uint16_t>(column)));
      writeGrapheme(cells, cell);
      break;
    case GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE:
      cell.style = {};
      cell.style.background = paletteColor(static_cast<Byte>(cell_layout::index(raw)));
      break;
    case GHOSTTY_CELL_CONTENT_BG_COLOR_RGB:
      cell.style = {};
      cell.style.background = rgbColor(GhosttyColorRgb{
          .r = static_cast<Byte>(cell_layout::r(raw)),
          .g = static_cast<Byte>(cell_layout::g(raw)),
          .b = static_cast<Byte>(cell_layout::b(raw)),
      });
      break;
    default:
      throw TerminalError{GHOSTTY_INVALID_VALUE};
    }

    destination[column] = cell;
  }
}

}
