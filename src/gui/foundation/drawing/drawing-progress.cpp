module telar.gui.foundation.drawing;

import std;

import telar.wire.vocabulary;
import telar.tbc;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::inline foundation::inline drawing {

  void ProgressRing::visit(PaintSink visitor) const {
    const auto side = std::min(area.width, area.height);
    if (!std::isfinite(side) || side <= 0 || !std::isfinite(fraction) || !std::isfinite(rotation) || !std::isfinite(stroke_width)) {
      return;
    }

    const auto stroke = stroke_width > 0 ? std::min(side / 2, stroke_width) : std::min(side / 4, std::max(1.0F, side * stroke_ratio));
    const Point origin{.x = area.x + ((area.width - side) / 2), .y = area.y + ((area.height - side) / 2)};
    auto ring_track = track.valueOr(color);

    if (!track) {
      ring_track.a *= track_alpha;
    }

    if (ring_track.a > 0) {
      visitor(RoundedRectanglePaint{.origin = origin, .shape = RoundedRectangle::resolve({.x = side, .y = side}, {.border = ring_track, .radius = side / 2, .border_width = stroke})});
    }

    const auto filled = std::clamp(fraction, 0.0F, 1.0F);
    if (std::equal_to<>{}(filled, 0.0F)) {
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

  Point ProgressRing::endpoint(float fraction) noexcept {
    const auto angle = static_cast<double>(fraction * (2 * std::numbers::pi_v<float>));

    return {.x = static_cast<float>(std::sin(angle)), .y = -static_cast<float>(std::cos(angle))};
  }

  // std::sin and std::cos are not constexpr, so the ring is computed as the program loads; a
  // function-local static instead would test its guard on every draw.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wglobal-constructors"
  const ds::Array<Point, ProgressRing::segments> ProgressRing::circle = [] noexcept {
    ds::Array<Point, segments> points{};

    for (std::size_t index = 0; index < points.size(); ++index) {
      points.atMut(index) = endpoint(static_cast<float>(index) / segments);
    }

    return points;
  }();
#pragma clang diagnostic pop

  void ProgressCapsule::visit(PaintSink append) const {
    if (state == PaneProgressState::remove || area.empty()) {
      return;
    }

    const auto geometry = ProgressGeometry::derive(area, ratio, state, compact);
    const auto bounds = geometry.background;
    auto background = color;

    background.a *= ProgressGeometry::background_alpha;
    append(RoundedRectanglePaint{.origin = {.x = bounds.x, .y = bounds.y}, .shape = RoundedRectangle::resolve({.x = bounds.width, .y = bounds.height}, {.fill = background, .radius = bounds.height / 2})});
    if (geometry.ring.width <= 0) {
      return;
    }

    ProgressRing{.area = geometry.ring, .color = color, .fraction = fraction, .rotation = rotation}.visit(append);
    for (std::size_t index = 0; index < geometry.mark_count; ++index) {
      const auto mark = geometry.marks[index];

      append(RoundedRectanglePaint{.origin = {.x = mark.x, .y = mark.y}, .shape = RoundedRectangle::resolve({.x = mark.width, .y = mark.height}, {.fill = color, .radius = geometry.mark_radius})});
    }
  }

  ProgressGeometry ProgressGeometry::derive(Rect area, float ratio, PaneProgressState state, bool compact) noexcept {
    ProgressGeometry geometry;
    const auto capsule_height = std::min(area.height, height * ratio);
    const auto capsule_width = compact ? std::min(area.width, compactWidth(ratio)) : area.width;

    geometry.background = {.x = area.x + area.width - capsule_width, .y = area.y + ((area.height - capsule_height) / 2), .width = capsule_width, .height = capsule_height};
    const auto side = std::max(0.0F, std::min({ring_side * ratio, capsule_height - (ring_inset * ratio), capsule_width - (2 * padding * ratio)}));

    geometry.ring = {.x = geometry.background.x + (padding * ratio), .y = geometry.background.y + ((capsule_height - side) / 2), .width = side, .height = side};
    if (side <= 0) {
      return geometry;
    }

    const auto stroke = std::max(1.0F, side * mark_stroke_ratio);
    const auto center = geometry.ring.x + (side / 2);
    const auto top = geometry.ring.y + (side * mark_top_ratio);

    geometry.mark_radius = stroke / 2;
    if (state == PaneProgressState::pause) {
      for (const auto offset : pause_offsets) {
        geometry.marks.atMut(geometry.mark_count++) = {.x = center + (offset * stroke), .y = top, .width = stroke, .height = side * pause_height_ratio};
      }
    } else if (state == PaneProgressState::error) {
      geometry.marks.atMut(geometry.mark_count++) = {.x = center - (stroke / 2), .y = top, .width = stroke, .height = side * error_height_ratio};
      geometry.marks.atMut(geometry.mark_count++) = {.x = center - (stroke / 2), .y = geometry.ring.y + (side * error_dot_ratio), .width = stroke, .height = stroke};
    }

    return geometry;
  }

}
