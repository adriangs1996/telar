module telar.gui.foundation.core;

import std;

import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::inline foundation::inline core {

  ds::Option<TerminalSize> TerminalGrid::fit(double width, double height) const noexcept {
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(scale) || width <= 0 || height <= 0 || scale <= 0 || cell_width_px == 0 || cell_height_px == 0) {
      return ds::none;
    }

    const auto available_columns = width * scale / cell_width_px;
    const auto available_rows = height * scale / cell_height_px;
    if (available_columns < 1 || available_rows < 1) {
      return ds::none;
    }

    const auto columns = static_cast<std::uint16_t>(std::clamp(std::floor(available_columns), 1.0, static_cast<double>(maximum_dimension)));
    const auto maximum_rows = std::min<std::size_t>(maximum_dimension, maximum_cells / columns);
    const auto rows = static_cast<std::uint16_t>(std::clamp(std::floor(available_rows), 1.0, static_cast<double>(maximum_rows)));

    return TerminalSize{.cols = columns, .rows = rows, .cell_width_px = cell_width_px, .cell_height_px = cell_height_px};
  }

}
