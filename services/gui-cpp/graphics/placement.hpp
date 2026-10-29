#pragma once

#include "core/geometry.hpp"
#include "display_box.hpp"
#include "source_rect.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace telar::gui {

struct ImageGeometry {
  Rect source;
  Rect destination;

  [[nodiscard]] ImageGeometry clipped(Rect bounds) const noexcept {
    if (source.empty() || destination.empty()) {
      return {};
    }

    if (destination.x >= bounds.x && destination.y >= bounds.y && destination.right() <= bounds.right() && destination.bottom() <= bounds.bottom()) {
      return *this;
    }

    const auto visible = destination.intersect(bounds);
    if (visible.empty()) {
      return {};
    }

    const auto horizontal = source.width / destination.width;
    const auto vertical = source.height / destination.height;

    return {.source = {.x = source.x + ((visible.x - destination.x) * horizontal), .y = source.y + ((visible.y - destination.y) * vertical), .width = visible.width * horizontal, .height = visible.height * vertical}, .destination = visible};
  }

  [[nodiscard]] static Rect textureSource(Rect source, Rect texture) noexcept {
    const auto width = texture.width;
    const auto height = texture.height;
    if (source.x + source.width > width || source.y + source.height > height) {
      return {.width = width, .height = height};
    }

    return source;
  }

  [[nodiscard]] static Rect remapSource(Rect fragment, Rect original, Rect substitute) noexcept {
    if (original.empty()) {
      return {};
    }

    const auto horizontal = substitute.width / original.width;
    const auto vertical = substitute.height / original.height;

    return {.x = substitute.x + ((fragment.x - original.x) * horizontal), .y = substitute.y + ((fragment.y - original.y) * vertical), .width = fragment.width * horizontal, .height = fragment.height * vertical};
  }

  static ImageGeometry resolve(const GraphicsPlacement &placement, const ImageDescription &image, Point cell, float scale) noexcept {
    if (scale <= 0 || !std::isfinite(scale)) {
      return {};
    }

    const auto source = ImageSourceRect::resolve(placement, image);
    const auto box = ImageDisplayBox::resolve(placement, source, physicalCell(cell, scale));

    return {.source = source.pixels(), .destination = {.x = static_cast<float>(box.x) / scale, .y = static_cast<float>(box.y) / scale, .width = static_cast<float>(box.width) / scale, .height = static_cast<float>(box.height) / scale}};
  }

  [[nodiscard]] static ImageDisplayBox::Cell physicalCell(Point logical, float scale) noexcept {
    if (scale <= 0 || !std::isfinite(scale)) {
      return {};
    }

    return {.width = physicalExtent(logical.x, scale), .height = physicalExtent(logical.y, scale)};
  }

private:
  [[nodiscard]] static std::uint32_t physicalExtent(float logical, float scale) noexcept {
    if (!std::isfinite(logical) || logical <= 0) {
      return 0;
    }

    const auto pixels = std::round(static_cast<double>(logical) * scale);
    const auto bounded = std::clamp(pixels, 0.0, static_cast<double>(std::numeric_limits<std::uint32_t>::max()));

    return static_cast<std::uint32_t>(bounded);
  }
};

inline bool placementOrder(const GraphicsPlacement &left, const GraphicsPlacement &right) noexcept {
  if (left.z_index != right.z_index) {
    return left.z_index < right.z_index;
  }

  if (left.key.image_id != right.key.image_id) {
    return left.key.image_id < right.key.image_id;
  }

  return left.virtual_id < right.virtual_id;
}

}
