#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include <cmath>
#include "curve_mask.hpp"
#include <span>
#include <stdexcept>
#include <limits>
#include <bit>
#include <concepts>
#include <functional>
#include <type_traits>
#include <utility>
#include <QQuickWindow>
#include <QSGNode>
#include <QtCore/qtypes.h>

#pragma once


import telar.gui.core.metrics;
import telar.gui.terminal.glyphs.curve_cache;

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
