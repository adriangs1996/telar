module telar.gui.foundation.fonts;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;

namespace telar::gui::inline foundation::inline fonts::glyphs {

  BoxCurve::BoxCurve(Shape shape, Rect cell, float thickness)
      : metrics_(BoxMetrics::resolve(cell, thickness)) {
    if (static_cast<std::size_t>(shape) >= shape_count) {
      throw std::invalid_argument{"InvalidBoxCurve"};
    }

    if (shape >= Shape::powerline_right_triangle) {
      powerline(shape);

      return;
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

  void BoxCurve::powerline(Shape shape) noexcept {
    const auto width = metrics_.width;
    const auto height = metrics_.height;
    const auto middle = height / 2;
    constexpr Point top_left{};
    const auto set = [this](std::initializer_list<Point> points) noexcept {
      std::ranges::copy(points, points_.begin());
      count_ = points.size();
    };

    // Even code points fill (triangles, half circles); odd ones stroke (angles, arcs, slashes).
    filled_ = (static_cast<std::size_t>(shape) - static_cast<std::size_t>(Shape::powerline_right_triangle)) % 2 == 0;
    switch (shape) {
    case Shape::powerline_right_triangle:
    case Shape::powerline_right_angle:
      set({top_left, {.x = width, .y = middle}, {.y = height}});
      break;
    case Shape::powerline_left_triangle:
    case Shape::powerline_left_angle:
      set({{.x = width}, {.y = middle}, {.x = width, .y = height}});
      break;
    case Shape::powerline_right_half_circle:
    case Shape::powerline_right_arc:
      halfEllipse(true);
      break;
    case Shape::powerline_left_half_circle:
    case Shape::powerline_left_arc:
      halfEllipse(false);
      break;
    case Shape::powerline_lower_left_triangle:
      set({top_left, {.x = width, .y = height}, {.y = height}});
      break;
    case Shape::powerline_lower_right_triangle:
      set({{.x = width}, {.x = width, .y = height}, {.y = height}});
      break;
    case Shape::powerline_upper_left_triangle:
      set({top_left, {.x = width}, {.y = height}});
      break;
    case Shape::powerline_upper_right_triangle:
      set({top_left, {.x = width}, {.x = width, .y = height}});
      break;
    case Shape::powerline_backslash:
    case Shape::powerline_backslash_redundant:
      set({top_left, {.x = width, .y = height}});
      break;
    case Shape::powerline_forwardslash:
    case Shape::powerline_forwardslash_redundant:
      set({{.y = height}, {.x = width}});
      break;
    default:
      break;
    }
  }

  // Half ellipse whose flat side is one vertical cell edge: it spans the full cell height,
  // so it joins the neighbouring background at any line height.
  void BoxCurve::halfEllipse(bool bulges_right) noexcept {
    const auto middle = metrics_.height / 2;
    const auto edge = bulges_right ? 0.0F : metrics_.width;
    const auto direction = bulges_right ? 1.0F : -1.0F;
    constexpr auto half_turn = std::numbers::pi_v<float>;

    for (std::size_t step = 0; step <= curve_segments; ++step) {
      const auto angle = (half_turn * static_cast<float>(step) / static_cast<float>(curve_segments)) - (half_turn / 2);

      points_[step] = {.x = edge + (direction * metrics_.width * std::cos(angle)), .y = middle + (middle * std::sin(angle))};
    }

    points_[0] = {.x = edge};
    points_[curve_segments] = {.x = edge, .y = metrics_.height};
    count_ = curve_segments + 1;
  }

  std::optional<BoxCurve::Shape> BoxCurve::shape(std::uint32_t codepoint) noexcept {
    if (codepoint >= Symbol::first_powerline && codepoint <= Symbol::last_powerline) {
      return static_cast<Shape>(static_cast<std::uint32_t>(Shape::powerline_right_triangle) + (codepoint - Symbol::first_powerline));
    }

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
        const auto coverage = filled_ ? std::clamp(((contains(point) ? distance : -distance) + (antialias / 2)) / antialias, 0.0F, 1.0F)
                                      : std::clamp(((metrics_.light / 2) + (antialias / 2) - distance) / antialias, 0.0F, 1.0F);

        pixels[column] = static_cast<std::uint8_t>(std::round(maximum_alpha * coverage));
      }
    }
  }

  BoxCurve::PixelBounds BoxCurve::rasterBounds(const AlphaRaster& raster, Point scale) const noexcept {
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

    if (filled_ && count_ > 2) {
      distance = std::min(distance, segmentDistance(point, {points_[count_ - 1], points_[0]}));
    }

    return distance;
  }

  // Even-odd test against the closed polygon.
  bool BoxCurve::contains(Point point) const noexcept {
    bool inside = false;

    for (std::size_t index = 0, previous = count_ - 1; index < count_; previous = index++) {
      const auto& first = points_[previous];
      const auto& last = points_[index];
      if ((first.y > point.y) != (last.y > point.y) && point.x < first.x + ((point.y - first.y) * (last.x - first.x) / (last.y - first.y))) {
        inside = !inside;
      }
    }

    return inside;
  }

  float BoxCurve::segmentDistance(Point point, const std::array<Point, 2>& segment) noexcept {
    const auto& first = segment.front();
    const auto& last = segment.back();
    const auto delta_x = last.x - first.x;
    const auto delta_y = last.y - first.y;
    const auto length = (delta_x * delta_x) + (delta_y * delta_y);
    const auto fraction = length == 0 ? 0 : std::clamp((((point.x - first.x) * delta_x) + ((point.y - first.y) * delta_y)) / length, 0.0F, 1.0F);
    const auto x = point.x - first.x - (fraction * delta_x);
    const auto y = point.y - first.y - (fraction * delta_y);

    return (x * x) + (y * y);
  }

}
