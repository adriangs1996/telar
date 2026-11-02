#pragma once

#include "core/color.hpp"
#include "core/geometry.hpp"
#include "curve_mask.hpp"
#include "terminal/glyphs/box_curve.hpp"
#include "terminal/glyphs/curve_cache.hpp"
#include <QQuickWindow>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <array>
#include <optional>

namespace telar::gui::qt {

struct CurvePaint {
  glyphs::BoxCurve::Shape shape = glyphs::BoxCurve::Shape::rounded_down_right;
  Rect cell;
  Color foreground;
  float thickness = 1;
  qreal scale = 1;
};

class CurveScene {
public:
  explicit CurveScene(QQuickWindow &window) noexcept;
  void paint(QSGNode &parent, const CurvePaint &paint);
  void reset() noexcept;

private:
  using Cache = glyphs::CurveCache<CurveMaskRef>;

  [[nodiscard]] std::optional<CurveMaskRef> createMask(glyphs::BoxCurve::Shape shape, Rect cell, float thickness);
  [[nodiscard]] CurveMaskRef mask(const CurvePaint &paint);
  void software(QSGNode &parent, const CurveMaskRef &mask, const CurvePaint &paint) const;

  QQuickWindow &window_;
  Cache masks_;
  std::array<std::optional<CurveMaskRef>, glyphs::BoxCurve::shape_count> fallback_{};
};

}
