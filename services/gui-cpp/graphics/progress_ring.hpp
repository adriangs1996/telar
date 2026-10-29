#pragma once

#include "core/color.hpp"
#include "core/geometry.hpp"
#include "rounded_rectangle.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <numbers>

namespace telar::gui {

struct ProgressRing {
  static constexpr std::size_t segments = 64;
  static constexpr std::size_t maximum_paints = segments + 2;
  static constexpr float stroke_ratio = 0.12F;
  static constexpr float track_alpha = 0.18F;
  Rect area;
  Color color;
  float fraction = 0;
  float rotation = 0;

  template <typename Visitor>
  void visit(Visitor visitor) const {
    const auto side = std::min(area.width, area.height);
    if (!std::isfinite(side) || side <= 0 || !std::isfinite(fraction) || !std::isfinite(rotation)) {
      return;
    }

    const auto stroke = std::min(side / 4, std::max(1.0F, side * stroke_ratio));
    const Point origin{.x = area.x + ((area.width - side) / 2), .y = area.y + ((area.height - side) / 2)};
    auto track = color;
    track.a *= track_alpha;
    visitor(RoundedRectanglePaint{.origin = origin, .shape = RoundedRectangle::resolve({.x = side, .y = side}, {.border = track, .radius = side / 2, .border_width = stroke})});
    const auto filled = std::clamp(fraction, 0.0F, 1.0F);
    if (filled == 0) {
      return;
    }

    const auto radius = (side - stroke) / 2;
    const auto axis = endpoint(rotation);
    const auto cosine = -axis.y;
    const auto sine = axis.x;
    const auto steps = static_cast<std::size_t>(std::ceil(filled * segments));
    for (std::size_t index = 0; index <= steps; ++index) {
      const auto point = index == steps ? endpoint(filled) : circle[index];
      const auto x = (point.x * cosine) - (point.y * sine);
      const auto y = (point.x * sine) + (point.y * cosine);
      visitor(RoundedRectanglePaint{.origin = {.x = origin.x + radius + (x * radius), .y = origin.y + radius + (y * radius)}, .shape = RoundedRectangle::resolve({.x = stroke, .y = stroke}, {.fill = color, .radius = stroke / 2})});
    }
  }

private:
  [[nodiscard]] static Point endpoint(float fraction) noexcept {
    const auto angle = static_cast<double>(fraction * (2 * std::numbers::pi_v<float>));

    return {.x = static_cast<float>(std::sin(angle)), .y = -static_cast<float>(std::cos(angle))};
  }

  inline static const auto circle = [] noexcept {
    std::array<Point, segments> points{};
    for (std::size_t index = 0; index < points.size(); ++index) {
      points[index] = endpoint(static_cast<float>(index) / segments);
    }

    return points;
  }();
};

}
