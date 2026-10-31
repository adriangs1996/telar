#include "native_rounded_rectangle.hpp"
#include "core/color.hpp"
#include "graphics/rounded_rectangle.hpp"
#include "rounded_rectangle_scene.hpp"
#include <QColor>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cmath>
#include <memory>

namespace telar::gui::qt {
namespace {

Color shapeColor(const QColor &color) {
  return {.r = color.redF(), .g = color.greenF(), .b = color.blueF(), .a = color.alphaF()};
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

QSGNode *NativeRoundedRectangle::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  const auto density = window() == nullptr ? 0 : window()->effectiveDevicePixelRatio();
  const auto physical_width = static_cast<float>(width() * density);
  const auto physical_height = static_cast<float>(height() * density);
  const auto transparent = color_.alphaF() <= 0 && (border_color_.alphaF() <= 0 || border_alpha_ == 0 || border_width_ <= 0);
  if (transparent || !std::isfinite(physical_width) || !std::isfinite(physical_height) || physical_width <= 0 || physical_height <= 0) {
    const auto retired = std::unique_ptr<QSGNode>{previous};

    return nullptr;
  }

  auto border = shapeColor(border_color_);
  border.a *= border_alpha_;
  const auto shape = RoundedRectangle::resolve({.x = physical_width, .y = physical_height}, {.fill = shapeColor(color_), .border = border, .radius = static_cast<float>(radius_ * density), .border_width = static_cast<float>(border_width_ * density)});

  return paintRoundedRectangle(*window(), previous, shape, density);
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
