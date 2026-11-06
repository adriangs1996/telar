#include "native_rounded_rectangle.hpp"
#include "core/color.hpp"
#include "core/geometry.hpp"
#include "graphics/rounded_rectangle.hpp"
#include "rounded_rectangle_scene.hpp"
#include <QColor>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <array>
#include <cmath>
#include <limits>
#include <memory>
#include <optional>

namespace telar::gui::qt {
namespace {

Color shapeColor(const QColor &color) {
  return {.r = color.redF(), .g = color.greenF(), .b = color.blueF(), .a = color.alphaF()};
}

std::optional<Rect> physicalClipBounds(const QRectF &bounds, qreal density) {
  const std::array values{bounds.x() * density, bounds.y() * density, bounds.width() * density, bounds.height() * density};
  constexpr auto maximum = static_cast<qreal>(std::numeric_limits<float>::max());
  for (const auto value : values) {
    if (!std::isfinite(value) || std::abs(value) > maximum) {
      return std::nullopt;
    }
  }

  return Rect{.x = static_cast<float>(values[0]), .y = static_cast<float>(values[1]), .width = static_cast<float>(values[2]), .height = static_cast<float>(values[3])};
}

}

NativeRoundedRectangle::NativeRoundedRectangle(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
}

QColor NativeRoundedRectangle::color() const {
  return color_;
}

void NativeRoundedRectangle::setColor(const QColor &color) {
  if (color.isValid() && color_ != color) {
    color_ = color;
    emit colorChanged();
    update();
  }
}

bool NativeRoundedRectangle::replaceBackground() const noexcept {
  return replace_background_;
}

void NativeRoundedRectangle::setReplaceBackground(bool replace) {
  if (replace_background_ != replace) {
    replace_background_ = replace;
    update();
    emit compositionChanged();
  }
}

QColor NativeRoundedRectangle::backdropColor() const {
  return backdrop_color_;
}

void NativeRoundedRectangle::setBackdropColor(const QColor &color) {
  if (color.isValid() && backdrop_color_ != color) {
    backdrop_color_ = color;
    update();
    emit compositionChanged();
  }
}

bool NativeRoundedRectangle::squareBottom() const noexcept {
  return square_bottom_;
}

void NativeRoundedRectangle::setSquareBottom(bool square) {
  if (square_bottom_ != square) {
    square_bottom_ = square;
    update();
    emit compositionChanged();
  }
}

QColor NativeRoundedRectangle::borderColor() const {
  return border_color_;
}

void NativeRoundedRectangle::setBorderColor(const QColor &color) {
  if (color.isValid() && border_color_ != color) {
    border_color_ = color;
    emit borderColorChanged();
    update();
  }
}

qreal NativeRoundedRectangle::borderAlpha() const noexcept {
  return border_alpha_;
}

void NativeRoundedRectangle::setBorderAlpha(qreal alpha) {
  if (!std::isfinite(alpha) || alpha < 0 || alpha > 1) {
    return;
  }

  const auto scalar = static_cast<float>(alpha);
  if (scalar != border_alpha_) {
    border_alpha_ = scalar;
    emit borderAlphaChanged();
    update();
  }
}

qreal NativeRoundedRectangle::radius() const noexcept {
  return radius_;
}

void NativeRoundedRectangle::setRadius(qreal radius) {
  if (std::isfinite(radius) && radius >= 0 && radius_ != radius) {
    radius_ = radius;
    emit radiusChanged();
    update();
  }
}

qreal NativeRoundedRectangle::borderWidth() const noexcept {
  return border_width_;
}

void NativeRoundedRectangle::setBorderWidth(qreal width) {
  if (std::isfinite(width) && width >= 0 && border_width_ != width) {
    border_width_ = width;
    emit borderWidthChanged();
    update();
  }
}

QRectF NativeRoundedRectangle::paintClip() const {
  return paint_clip_.value_or(QRectF{});
}

void NativeRoundedRectangle::setPaintClip(const QRectF &bounds) {
  if (!std::isfinite(bounds.x()) || !std::isfinite(bounds.y()) || !std::isfinite(bounds.width()) || !std::isfinite(bounds.height()) || bounds.width() < 0 || bounds.height() < 0 || paint_clip_ == bounds) {
    return;
  }

  paint_clip_ = bounds;
  emit paintClipChanged();
  update();
}

void NativeRoundedRectangle::resetPaintClip() {
  if (paint_clip_) {
    paint_clip_.reset();
    emit paintClipChanged();
    update();
  }
}

QSGNode *NativeRoundedRectangle::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  const auto density = window() == nullptr ? 0 : window()->effectiveDevicePixelRatio();
  const auto physical_width = static_cast<float>(width() * density);
  const auto physical_height = static_cast<float>(height() * density);
  const auto transparent = !replace_background_ && color_.alphaF() <= 0 && (border_color_.alphaF() <= 0 || border_alpha_ == 0 || border_width_ <= 0);
  if (transparent || !std::isfinite(physical_width) || !std::isfinite(physical_height) || physical_width <= 0 || physical_height <= 0) {
    const auto retired = std::unique_ptr<QSGNode>{previous};

    return nullptr;
  }

  auto border = shapeColor(border_color_);
  border.a *= border_alpha_;
  const auto shape = RoundedRectangle::resolve({.x = physical_width, .y = physical_height}, {.fill = shapeColor(color_), .border = border, .radius = static_cast<float>(radius_ * density), .border_width = static_cast<float>(border_width_ * density), .backdrop = shapeColor(backdrop_color_), .replace_background = replace_background_, .square_bottom = square_bottom_});

  RoundedRectanglePaint paint{.shape = shape};
  if (paint_clip_) {
    const auto clip = physicalClipBounds(*paint_clip_, density);
    if (!clip) {
      const auto retired = std::unique_ptr<QSGNode>{previous};

      return nullptr;
    }

    paint = paint.clipped(*clip);
    if (paint.shape.size.x <= 0 || paint.shape.size.y <= 0) {
      const auto retired = std::unique_ptr<QSGNode>{previous};

      return nullptr;
    }
  }

  return paintRoundedRectangleAt(*window(), previous, paint, density);
}

void NativeRoundedRectangle::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  update();
}

void NativeRoundedRectangle::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
  }

  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange || change == ItemParentHasChanged) {
    update();
  }
}

}
