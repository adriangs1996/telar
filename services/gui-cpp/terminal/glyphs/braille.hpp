#pragma once

#include "core/geometry.hpp"
#include "ink.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace telar::gui::glyphs {

class Braille {
public:
  static constexpr std::size_t dot_count = 8;
  using Paint = Ink<dot_count>;

  [[nodiscard]] static Paint draw(Rect cell, std::uint8_t dots) {
    validateCell(cell);
    const auto grid = cell.width < columns || cell.height < rows ? fractionalGrid(cell) : integerGrid(cell);
    Paint result;
    if (grid.diameter == 0) {
      return result;
    }

    constexpr std::array<unsigned, dot_count> dot_columns{0, 0, 0, 1, 1, 1, 0, 1};
    constexpr std::array<unsigned, dot_count> dot_rows{0, 1, 2, 0, 1, 2, 3, 3};
    for (std::size_t bit = 0; bit < dot_count; ++bit) {
      if ((dots & (1U << bit)) != 0) {
        result.push({.x = grid.x[dot_columns[bit]], .y = grid.y[dot_rows[bit]], .width = grid.diameter, .height = grid.diameter});
      }
    }

    return result;
  }

private:
  static constexpr int columns = 2;
  static constexpr int rows = 4;
  static constexpr int horizontal_divisions = 2 * columns;
  static constexpr int vertical_divisions = 2 * rows;

  struct Grid {
    std::array<float, columns> x{};
    std::array<float, rows> y{};
    float diameter = 0;
  };

  [[nodiscard]] static Grid fractionalGrid(Rect cell) noexcept {
    const auto diameter = std::min(cell.width / columns, cell.height / rows);
    constexpr std::array<float, rows> row_centers{1, 3, 5, 7};
    Grid result{.x = {cell.x + (cell.width / horizontal_divisions) - (diameter / 2), cell.x + (3 * cell.width / horizontal_divisions) - (diameter / 2)}, .diameter = diameter};
    for (std::size_t row = 0; row < result.y.size(); ++row) {
      result.y[row] = cell.y + (row_centers[row] * cell.height / vertical_divisions) - (diameter / 2);
    }

    return result;
  }

  [[nodiscard]] static Grid integerGrid(Rect cell) noexcept {
    const auto width = static_cast<int>(cell.width);
    const auto height = static_cast<int>(cell.height);
    auto diameter = std::min(width / horizontal_divisions, height / vertical_divisions);
    auto x_spacing = width / horizontal_divisions;
    auto y_spacing = height / vertical_divisions;
    auto x_margin = x_spacing / 2;
    auto y_margin = y_spacing / 2;
    auto x_remaining = width - (2 * x_margin) - x_spacing - (columns * diameter);
    auto y_remaining = height - (2 * y_margin) - ((rows - 1) * y_spacing) - (rows * diameter);
    if (x_remaining >= columns && y_remaining >= rows && diameter == 0) {
      ++diameter;
      x_remaining -= columns;
      y_remaining -= rows;
    }

    if (x_remaining >= 2 && x_margin == 0) {
      x_margin = 1;
      x_remaining -= 2;
    }

    if (y_remaining >= 2 && y_margin == 0) {
      y_margin = 1;
      y_remaining -= 2;
    }

    if (x_remaining >= 1) {
      ++x_spacing;
      --x_remaining;
    }

    if (y_remaining >= rows - 1) {
      ++y_spacing;
      y_remaining -= rows - 1;
    }

    if (x_remaining >= 2) {
      ++x_margin;
      x_remaining -= 2;
    }

    if (y_remaining >= 2) {
      ++y_margin;
      y_remaining -= 2;
    }

    if (x_remaining >= columns && y_remaining >= rows) {
      ++diameter;
    }

    Grid result{.diameter = static_cast<float>(diameter)};
    for (std::size_t column = 0; column < result.x.size(); ++column) {
      result.x[column] = cell.x + static_cast<float>(x_margin + (static_cast<int>(column) * (diameter + x_spacing)));
    }

    for (std::size_t row = 0; row < result.y.size(); ++row) {
      result.y[row] = cell.y + static_cast<float>(y_margin + (static_cast<int>(row) * (diameter + y_spacing)));
    }

    return result;
  }
};

}
