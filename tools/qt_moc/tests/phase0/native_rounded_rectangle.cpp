module telar.phase0.rounded_rect;

import std;
import telar.qt;

namespace telar::gui::qt {

  NativeRoundedRectangle::NativeRoundedRectangle(QQuickItem* parent)
      : QQuickItem(parent) {
    setFlag(ItemHasContents);
  }

  QColor NativeRoundedRectangle::color() const {
    return color_;
  }

  void NativeRoundedRectangle::setColor(const QColor& color) {
    if (color.isValid() && color_ != color) {
      color_ = color;
      colorChanged();
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
      compositionChanged();
    }
  }

  QColor NativeRoundedRectangle::backdropColor() const {
    return backdrop_color_;
  }

  void NativeRoundedRectangle::setBackdropColor(const QColor& color) {
    if (color.isValid() && backdrop_color_ != color) {
      backdrop_color_ = color;
      update();
      compositionChanged();
    }
  }

  QColor NativeRoundedRectangle::borderColor() const {
    return border_color_;
  }

  void NativeRoundedRectangle::setBorderColor(const QColor& color) {
    if (color.isValid() && border_color_ != color) {
      border_color_ = color;
      borderColorChanged();
      update();
    }
  }

  qreal NativeRoundedRectangle::borderAlpha() const noexcept {
    return static_cast<qreal>(border_alpha_);
  }

  void NativeRoundedRectangle::setBorderAlpha(qreal alpha) {
    if (!std::isfinite(alpha) || alpha < 0 || alpha > 1) {
      return;
    }

    const auto scalar = static_cast<float>(alpha);
    if (!std::equal_to<>{}(scalar, border_alpha_)) {
      border_alpha_ = scalar;
      borderAlphaChanged();
      update();
    }
  }

  qreal NativeRoundedRectangle::radius() const noexcept {
    return radius_;
  }

  void NativeRoundedRectangle::setRadius(qreal radius) {
    if (std::isfinite(radius) && radius >= 0 && !std::equal_to<>{}(radius_, radius)) {
      radius_ = radius;
      radiusChanged();
      update();
    }
  }

  qreal NativeRoundedRectangle::borderWidth() const noexcept {
    return border_width_;
  }

  void NativeRoundedRectangle::setBorderWidth(qreal width) {
    if (std::isfinite(width) && width >= 0 && !std::equal_to<>{}(border_width_, width)) {
      border_width_ = width;
      borderWidthChanged();
      update();
    }
  }

  QRectF NativeRoundedRectangle::paintClip() const {
    return paint_clip_.value_or(QRectF{});
  }

  void NativeRoundedRectangle::setPaintClip(const QRectF& bounds) {
    if (paint_clip_ == bounds) {
      return;
    }

    paint_clip_ = bounds;
    paintClipChanged();
    update();
  }

  void NativeRoundedRectangle::resetPaintClip() {
    if (paint_clip_) {
      paint_clip_.reset();
      paintClipChanged();
      update();
    }
  }

  qreal NativeRoundedRectangle::effectiveRadius() const noexcept {
    return radius_ + border_width_;
  }

}
