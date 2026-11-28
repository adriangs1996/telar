module telar.gui.ui.app.panes.header;

import std;
import telar.gui.qt;
import telar.gui.application;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  PaneHeaderLayout::PaneHeaderLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  QVariantMap PaneHeaderLayout::measurements() const {
    return measurements_;
  }

  void PaneHeaderLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      measurementsChanged();
      polish();
    }
  }

  qreal PaneHeaderLayout::ratio() const noexcept {
    return ratio_;
  }

  void PaneHeaderLayout::setRatio(qreal ratio) {
    if (std::isfinite(ratio) && ratio > 0 && std::not_equal_to<>{}(ratio_, ratio)) {
      ratio_ = ratio;
      metricsChanged();
      polish();
    }
  }

  qreal PaneHeaderLayout::bandHeight() const noexcept {
    return band_height_;
  }

  void PaneHeaderLayout::setBandHeight(qreal height) {
    if (std::isfinite(height) && height >= 0 && std::not_equal_to<>{}(band_height_, height)) {
      band_height_ = height;
      metricsChanged();
      polish();
    }
  }

  QVariantMap PaneHeaderLayout::style() const {
    return paneChromeStyle(ratio_, density_);
  }

  QRectF PaneHeaderLayout::logical(Rect bounds) const noexcept {
    return {static_cast<qreal>(bounds.x) / density_, static_cast<qreal>(bounds.y) / density_, static_cast<qreal>(bounds.width) / density_, static_cast<qreal>(bounds.height) / density_};
  }

  QRectF PaneHeaderLayout::indexBounds() const noexcept {
    return logical(layout_.index);
  }

  QRectF PaneHeaderLayout::nameBounds() const noexcept {
    return logical(layout_.name);
  }

  QRectF PaneHeaderLayout::pausedBounds() const noexcept {
    return logical(layout_.paused);
  }

  QRectF PaneHeaderLayout::chipBounds() const noexcept {
    return logical(layout_.chip);
  }

  QRectF PaneHeaderLayout::progressBounds() const noexcept {
    return logical(layout_.progress);
  }

  bool PaneHeaderLayout::compactProgress() const noexcept {
    return layout_.compact_progress;
  }

  void PaneHeaderLayout::refreshLayout() {
    const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const auto advance = [&](const QString& name) {
      const auto value = measurements_.value(name).toDouble();

      return std::isfinite(value) && value > 0 ? static_cast<float>(value * density) : 0;
    };

    const application::workbench::PaneHeaderMeasurements measurements{
        .index = advance(u"index"_s),
        .name = advance(u"name"_s),
        .chip = advance(u"chip"_s),
        .paused = advance(u"paused"_s),
        .progress = advance(u"progress"_s),
        .compact_progress = advance(u"compactProgress"_s),
        .needs_attention = measurements_.value(u"needsAttention"_s).toBool(),
    };

    const auto layout = application::workbench::PaneHeaderGeometry::derive({.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)}, {.ratio = static_cast<float>(ratio_ * density), .maximum_band_height = static_cast<float>(band_height_ * density)}, measurements);
    if (layout != layout_ || std::not_equal_to<>{}(density_, density)) {
      layout_ = layout;
      density_ = density;
      metricsChanged();
      layoutChanged();
    }
  }

  void PaneHeaderLayout::updatePolish() {
    refreshLayout();
  }

  void PaneHeaderLayout::componentComplete() {
    QQuickItem::componentComplete();
    refreshLayout();
  }

  void PaneHeaderLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void PaneHeaderLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

}
