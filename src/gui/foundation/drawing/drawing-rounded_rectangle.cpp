module telar.gui.foundation.drawing;

import std;

import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline drawing {

  void PaintSink::operator()(const RoundedRectanglePaint& paint) const {
    call(context, paint);
  }

  RoundedRectangle RoundedRectangle::resolve(Point size, RoundedRectangleStyle style) noexcept {
    style.radius = std::min(style.radius, std::min(size.x, size.y) / 2);

    return {.size = size, .style = style};
  }

  Color RoundedRectangle::sample(Point local) const noexcept {
    if (std::equal_to<>{}(style.radius, 0.0F) && std::equal_to<>{}(style.border_width, 0.0F)) {
      return style.fill;
    }

    constexpr float pixel_center = 0.5F;
    const Point half_size{.x = size.x * pixel_center, .y = size.y * pixel_center};
    const auto radius = style.radius;
    const auto horizontal = std::abs(local.x - half_size.x) - half_size.x + radius;
    const auto vertical = std::abs(local.y - half_size.y) - half_size.y + radius;
    const auto outside_horizontal = std::max(horizontal, 0.0F);
    const auto outside_vertical = std::max(vertical, 0.0F);
    const auto distance = std::sqrt((outside_horizontal * outside_horizontal) + (outside_vertical * outside_vertical)) + std::min(std::max(horizontal, vertical), 0.0F) - radius;
    const auto outer = 1 - std::clamp(distance + pixel_center, 0.0F, 1.0F);
    const auto inner = 1 - std::clamp(distance + style.border_width + pixel_center, 0.0F, 1.0F);
    const auto fill_alpha = style.fill.a * inner;
    const auto border_alpha = style.border.a * (outer - inner);
    const auto backdrop_alpha = style.replace_background ? style.backdrop.a * (1 - outer) : 0;
    const auto alpha = fill_alpha + border_alpha + backdrop_alpha;
    if (alpha <= 0) {
      return {.a = 0};
    }

    return {.r = ((style.fill.r * fill_alpha) + (style.border.r * border_alpha) + (style.backdrop.r * backdrop_alpha)) / alpha, .g = ((style.fill.g * fill_alpha) + (style.border.g * border_alpha) + (style.backdrop.g * backdrop_alpha)) / alpha, .b = ((style.fill.b * fill_alpha) + (style.border.b * border_alpha) + (style.backdrop.b * backdrop_alpha)) / alpha, .a = alpha};
  }

  RoundedRectanglePaint RoundedRectanglePaint::clipped(Rect clip) const noexcept {
    const auto size = shape.size;
    if (origin.x >= clip.x && origin.y >= clip.y && origin.x + size.x <= clip.x + clip.width && origin.y + size.y <= clip.y + clip.height) {
      return *this;
    }

    const auto left = std::fmax(origin.x, clip.x);
    const auto top = std::fmax(origin.y, clip.y);
    const auto right = std::fmax(left, std::fmin(origin.x + size.x, clip.x + clip.width));
    const auto bottom = std::fmax(top, std::fmin(origin.y + size.y, clip.y + clip.height));
    auto paint = *this;

    paint.origin = {.x = left, .y = top};
    paint.shape.size = {.x = right - left, .y = bottom - top};

    return paint;
  }

}
