module;

#include <cstddef>
#include <cstdint>
#include <cmath>

module telar.gui.terminal.glyphs.curve_cache;

import std;

import telar.gui.terminal.font_grid;

import telar.gui.core.metrics;
import telar.gui.terminal.copy_mode;


namespace telar::gui::glyphs {

BoxCurve::BoxCurve(Shape shape, Rect cell, float thickness)
    : metrics_(BoxMetrics::resolve(cell, thickness)) {
  if (static_cast<std::size_t>(shape) >= shape_count) {
    throw std::invalid_argument{"InvalidBoxCurve"};
  }

  if (shape >= Shape::rising_diagonal) {
    points_[0] = {.y = shape == Shape::rising_diagonal ? metrics_.height : 0};
    points_[1] = {.x = metrics_.width, .y = shape == Shape::rising_diagonal ? 0 : metrics_.height};
    count_ = 2;
    cross_ = shape == Shape::diagonal_cross;

    return;
  }

  const auto right = shape == Shape::rounded_down_right || shape == Shape::rounded_up_right;
  const auto down = shape == Shape::rounded_down_right || shape == Shape::rounded_down_left;
  const auto x_direction = right ? 1.0F : -1.0F;
  const auto y_direction = down ? 1.0F : -1.0F;
  const auto center_x = std::floor((metrics_.width - metrics_.light) / 2) + (metrics_.light / 2);
  const auto center_y = std::floor((metrics_.height - metrics_.light) / 2) + (metrics_.light / 2);
  const auto radius = std::min(metrics_.width, metrics_.height) / 2;
  points_[0] = {.x = center_x, .y = down ? metrics_.height : 0};
  constexpr float cubic_control_weight = 0.75F;
  for (std::size_t step = 0; step <= curve_segments; ++step) {
    const auto fraction = static_cast<float>(step) / static_cast<float>(curve_segments);
    const auto remaining = 1 - fraction;
    points_[step + 1] = {
        .x = center_x + (x_direction * radius * ((cubic_control_weight * remaining * fraction * fraction) + (fraction * fraction * fraction))),
        .y = center_y + (y_direction * radius * ((remaining * remaining * remaining) + (cubic_control_weight * remaining * remaining * fraction))),
    };
  }

  points_.back() = {.x = right ? metrics_.width : 0, .y = center_y};
  count_ = points_.size();
}

std::optional<BoxCurve::Shape> BoxCurve::shape(std::uint32_t codepoint) noexcept {
  if (codepoint < Symbol::first_box_curve || codepoint > Symbol::last_box_curve) {
    return std::nullopt;
  }

  return static_cast<Shape>(codepoint - Symbol::first_box_curve);
}

void BoxCurve::rasterize(AlphaRaster raster) const {
  raster.validate();
  if (raster.empty()) {
    return;
  }

  const Point scale{.x = metrics_.width / static_cast<float>(raster.width), .y = metrics_.height / static_cast<float>(raster.height)};
  const auto antialias = std::max(scale.x, scale.y);
  const auto bounds = scale.x > 0 && scale.y > 0 ? rasterBounds(raster, scale) : PixelBounds{};
  constexpr float maximum_alpha = std::numeric_limits<std::uint8_t>::max();
  for (std::size_t row = 0; row < raster.height; ++row) {
    const auto pixels = raster.pixels.subspan(row * raster.stride, raster.width);
    std::ranges::fill(pixels, 0);
    if (row < bounds.top || row >= bounds.bottom) {
      continue;
    }

    for (auto column = bounds.left; column < bounds.right; ++column) {
      const Point point{.x = (static_cast<float>(column) + 0.5F) * scale.x, .y = (static_cast<float>(row) + 0.5F) * scale.y};
      const auto distance = std::sqrt(distanceSquared(point));
      const auto coverage = std::clamp(((metrics_.light / 2) + (antialias / 2) - distance) / antialias, 0.0F, 1.0F);
      pixels[column] = static_cast<std::uint8_t>(std::round(maximum_alpha * coverage));
    }
  }
}

BoxCurve::PixelBounds BoxCurve::rasterBounds(const AlphaRaster &raster, Point scale) const noexcept {
  auto left = metrics_.width;
  auto top = metrics_.height;
  float right = 0;
  float bottom = 0;
  for (const auto point : std::span{points_}.first(count_)) {
    left = std::min(left, point.x);
    top = std::min(top, point.y);
    right = std::max(right, point.x);
    bottom = std::max(bottom, point.y);
  }

  const auto margin = (metrics_.light + std::max(scale.x, scale.y)) / 2;

  return {
      .left = static_cast<std::size_t>(std::clamp(std::floor((left - margin) / scale.x), 0.0F, static_cast<float>(raster.width))),
      .top = static_cast<std::size_t>(std::clamp(std::floor((top - margin) / scale.y), 0.0F, static_cast<float>(raster.height))),
      .right = static_cast<std::size_t>(std::clamp(std::ceil((right + margin) / scale.x), 0.0F, static_cast<float>(raster.width))),
      .bottom = static_cast<std::size_t>(std::clamp(std::ceil((bottom + margin) / scale.y), 0.0F, static_cast<float>(raster.height))),
  };
}

float BoxCurve::distanceSquared(Point point) const noexcept {
  auto distance = std::numeric_limits<float>::infinity();
  for (std::size_t index = 1; index < count_; ++index) {
    distance = std::min(distance, segmentDistance(point, {points_[index - 1], points_[index]}));
  }

  if (cross_) {
    distance = std::min(distance, segmentDistance(point, {{{.y = metrics_.height}, {.x = metrics_.width}}}));
  }

  return distance;
}

float BoxCurve::segmentDistance(Point point, const std::array<Point, 2> &segment) noexcept {
  const auto &first = segment.front();
  const auto &last = segment.back();
  const auto delta_x = last.x - first.x;
  const auto delta_y = last.y - first.y;
  const auto length = (delta_x * delta_x) + (delta_y * delta_y);
  const auto fraction = length == 0 ? 0 : std::clamp((((point.x - first.x) * delta_x) + ((point.y - first.y) * delta_y)) / length, 0.0F, 1.0F);
  const auto x = point.x - first.x - (fraction * delta_x);
  const auto y = point.y - first.y - (fraction * delta_y);

  return (x * x) + (y * y);
}

}
