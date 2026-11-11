#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "native_progress_ring.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include <cmath>
#include <numbers>
#include "rounded_paints_scene.hpp"
#include <QColor>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <limits>
#include <memory>



import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;

namespace telar::gui::qt {

NativeProgressRing::NativeProgressRing(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
}

QColor NativeProgressRing::color() const {
  return color_;
}

qreal NativeProgressRing::fraction() const noexcept {
  return fraction_;
}

qreal NativeProgressRing::turns() const noexcept {
  return turns_;
}

void NativeProgressRing::setColor(const QColor &color) {
  if (color.isValid() && color_ != color) {
    color_ = color;
    update();
    emit colorChanged();
  }
}

void NativeProgressRing::setFraction(qreal fraction) {
  if (std::isfinite(fraction)) {
    const auto bounded = std::clamp(fraction, 0.0, 1.0);
    if (fraction_ != bounded) {
      fraction_ = bounded;
      update();
      emit fractionChanged();
    }
  }
}

void NativeProgressRing::setTurns(qreal turns) {
  if (std::isfinite(turns) && std::abs(turns) <= std::numeric_limits<float>::max() && turns_ != turns) {
    turns_ = turns;
    update();
    emit turnsChanged();
  }
}

qreal NativeProgressRing::strokeWidth() const noexcept {
  return stroke_width_;
}

void NativeProgressRing::setStrokeWidth(qreal width) {
  if (std::isfinite(width) && width >= 0 && width <= std::numeric_limits<float>::max() && stroke_width_ != width) {
    stroke_width_ = width;
    update();
    emit strokeWidthChanged();
  }
}

QColor NativeProgressRing::trackColor() const {
  return track_color_;
}

void NativeProgressRing::setTrackColor(const QColor &color) {
  if (color.isValid() && track_color_ != color) {
    track_color_ = color;
    update();
    emit trackColorChanged();
  }
}

QSGNode *NativeProgressRing::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  auto root = std::unique_ptr<QSGNode>{previous};
  if (window() == nullptr || width() <= 0 || height() <= 0 || color_.alphaF() <= 0) {
    return nullptr;
  }

  const Color color{.r = color_.redF(), .g = color_.greenF(), .b = color_.blueF(), .a = color_.alphaF()};
  const auto track = track_color_.isValid() ? std::optional<Color>{Color{.r = track_color_.redF(), .g = track_color_.greenF(), .b = track_color_.blueF(), .a = track_color_.alphaF()}} : std::nullopt;

  return paintRoundedShapes<ProgressRing::maximum_paints>(*this, root.release(), [&](auto append, Rect area) {
    ProgressRing{.area = area, .color = color, .fraction = static_cast<float>(fraction_), .rotation = static_cast<float>(turns_), .stroke_width = static_cast<float>(stroke_width_), .track = track}.visit(append);
  });
}

void NativeProgressRing::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
  }

  if (change == ItemParentHasChanged || change == ItemSceneChange || change == ItemDevicePixelRatioHasChanged) {
    update();
  }
}

void NativeProgressRing::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  update();
}

}
