#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {

inline constexpr TerminalSize default_terminal_size{
    .cols = 80,
    .rows = 24,
    .cell_width_px = 9,
    .cell_height_px = 18,
};

struct TerminalGrid {
  static constexpr std::uint16_t maximum_dimension = std::numeric_limits<std::uint16_t>::max();
  static constexpr std::size_t maximum_cells = 130359;

  std::uint16_t cell_width_px = default_terminal_size.cell_width_px;
  std::uint16_t cell_height_px = default_terminal_size.cell_height_px;
  double scale = 1;

  bool operator==(const TerminalGrid &) const = default;

  [[nodiscard]] std::optional<TerminalSize> fit(double width, double height) const noexcept {
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(scale) || width <= 0 || height <= 0 || scale <= 0 || cell_width_px == 0 || cell_height_px == 0) {
      return std::nullopt;
    }

    const auto available_columns = width * scale / cell_width_px;
    const auto available_rows = height * scale / cell_height_px;
    if (available_columns < 1 || available_rows < 1) {
      return std::nullopt;
    }

    const auto columns = static_cast<std::uint16_t>(std::clamp(std::floor(available_columns), 1.0, static_cast<double>(maximum_dimension)));
    const auto maximum_rows = std::min<std::size_t>(maximum_dimension, maximum_cells / columns);
    const auto rows = static_cast<std::uint16_t>(std::clamp(std::floor(available_rows), 1.0, static_cast<double>(maximum_rows)));

    return TerminalSize{.cols = columns, .rows = rows, .cell_width_px = cell_width_px, .cell_height_px = cell_height_px};
  }
};

}
