#pragma once

#include "alpha_raster.hpp"
#include "box_metrics.hpp"
#include "core/geometry.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace telar::gui::glyphs {

class BoxCurve {
public:
  enum class Shape : std::uint8_t {
    rounded_down_right,
    rounded_down_left,
    rounded_up_left,
    rounded_up_right,
    rising_diagonal,
    falling_diagonal,
    diagonal_cross,
  };

  static constexpr std::size_t shape_count = 7;

  BoxCurve(Shape shape, Rect cell, float thickness);
  [[nodiscard]] static std::optional<Shape> shape(std::uint32_t codepoint) noexcept;
  void rasterize(AlphaRaster raster) const;

private:
  static constexpr std::size_t curve_segments = 16;
  static constexpr std::size_t point_capacity = curve_segments + 3;

  struct PixelBounds {
    std::size_t left = 0;
    std::size_t top = 0;
    std::size_t right = 0;
    std::size_t bottom = 0;
  };

  [[nodiscard]] PixelBounds rasterBounds(const AlphaRaster &raster, Point scale) const noexcept;
  [[nodiscard]] float distanceSquared(Point point) const noexcept;
  [[nodiscard]] static float segmentDistance(Point point, const std::array<Point, 2> &segment) noexcept;

  BoxMetrics metrics_;
  std::array<Point, point_capacity> points_{};
  std::size_t count_ = 0;
  bool cross_ = false;
};

}
