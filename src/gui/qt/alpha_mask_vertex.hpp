#pragma once

#include <QPointF>
#include <QRectF>
#include <QSGGeometry>
#include <array>
#include <cstddef>
#include <span>

namespace telar::gui::qt {

struct AlphaMaskVertex {
  float x = 0;
  float y = 0;
  float u = 0;
  float v = 0;
  float opacity = 1;
};

inline constexpr std::size_t alpha_mask_triangle_vertices = 6;

inline void writeAlphaMaskQuad(std::span<AlphaMaskVertex, alpha_mask_triangle_vertices> vertices, const QRectF &bounds, const QRectF &source, float opacity) noexcept {
  constexpr std::array corners{QPointF{0, 0}, QPointF{1, 0}, QPointF{1, 1}, QPointF{0, 0}, QPointF{1, 1}, QPointF{0, 1}};
  for (std::size_t index = 0; index < corners.size(); ++index) {
    const auto corner = corners[index];
    vertices[index] = {.x = static_cast<float>(bounds.x() + (corner.x() * bounds.width())), .y = static_cast<float>(bounds.y() + (corner.y() * bounds.height())), .u = static_cast<float>(source.x() + (corner.x() * source.width())), .v = static_cast<float>(source.y() + (corner.y() * source.height())), .opacity = opacity};
  }
}

inline const QSGGeometry::AttributeSet &alphaMaskAttributes() noexcept {
  static const std::array attributes{
      QSGGeometry::Attribute::create(0, 2, QSGGeometry::FloatType, true),
      QSGGeometry::Attribute::create(1, 2, QSGGeometry::FloatType),
      QSGGeometry::Attribute::create(2, 1, QSGGeometry::FloatType),
  };
  static const QSGGeometry::AttributeSet layout{.count = static_cast<int>(attributes.size()), .stride = sizeof(AlphaMaskVertex), .attributes = attributes.data()};

  return layout;
}

}
