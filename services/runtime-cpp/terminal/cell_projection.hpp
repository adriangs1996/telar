#pragma once

#include "ghostty_handle.hpp"
#include "screen.hpp"
#include <array>

namespace telar::runtime {

class CellProjection {
public:
  void updateColors(GhosttyTerminal terminal, GhosttyRenderState render_state);
  void copyRow(GhosttyRenderStateRowIterator row, GhosttyRenderStateRowCells cells, std::span<ScreenCell> destination) const;

private:
  CellColor paletteColor(Byte index) const noexcept;
  CellColor resolveColor(const GhosttyStyleColor &color, CellColor fallback) const noexcept;
  CellStyle translateStyle(const GhosttyStyle &style) const noexcept;
  static void writeGrapheme(GhosttyRenderStateRowCells cells, ScreenCell &destination);

  GhosttyRenderStateColors colors_ = ghosttySized<GhosttyRenderStateColors>();
  std::array<Byte, 256> palette_overrides_{};
  CellStyle default_style_{};
};

}
