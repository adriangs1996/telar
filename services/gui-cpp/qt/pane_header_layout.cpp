#include "pane_header_layout.hpp"
#include "core/geometry.hpp"
#include "pane_chrome_style.hpp"
#include "presentation/pane_chrome.hpp"
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cmath>

namespace telar::gui::qt {

PaneHeaderLayout::PaneHeaderLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap PaneHeaderLayout::measurements() const {
  return measurements_;
}

void PaneHeaderLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    emit measurementsChanged();
    polish();
  }
}

qreal PaneHeaderLayout::ratio() const noexcept {
  return ratio_;
}

void PaneHeaderLayout::setRatio(qreal ratio) {
  if (std::isfinite(ratio) && ratio > 0 && ratio_ != ratio) {
    ratio_ = ratio;
    emit metricsChanged();
    polish();
  }
}

qreal PaneHeaderLayout::bandHeight() const noexcept {
  return band_height_;
}

void PaneHeaderLayout::setBandHeight(qreal height) {
  if (std::isfinite(height) && height >= 0 && band_height_ != height) {
    band_height_ = height;
    emit metricsChanged();
    polish();
  }
}

QVariantMap PaneHeaderLayout::style() const {
  return paneChromeStyle(ratio_, density_);
}

QRectF PaneHeaderLayout::logical(Rect bounds) const noexcept {
  return {bounds.x / density_, bounds.y / density_, bounds.width / density_, bounds.height / density_};
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
  const auto advance = [&](const QString &name) {
    const auto value = measurements_.value(name).toDouble();

    return std::isfinite(value) && value > 0 ? static_cast<float>(value * density) : 0;
  };
  const PaneHeaderMeasurements measurements{
      .index = advance(QStringLiteral("index")),
      .name = advance(QStringLiteral("name")),
      .chip = advance(QStringLiteral("chip")),
      .paused = advance(QStringLiteral("paused")),
      .progress = advance(QStringLiteral("progress")),
      .compact_progress = advance(QStringLiteral("compactProgress")),
      .needs_attention = measurements_.value(QStringLiteral("needsAttention")).toBool(),
  };
  const auto layout = PaneHeaderGeometry::derive({.width = static_cast<float>(width() * density), .height = static_cast<float>(height() * density)}, {.ratio = static_cast<float>(ratio_ * density), .maximum_band_height = static_cast<float>(band_height_ * density)}, measurements);
  if (layout != layout_ || density_ != density) {
    layout_ = layout;
    density_ = density;
    emit metricsChanged();
    emit layoutChanged();
  }
}

void PaneHeaderLayout::updatePolish() {
  refreshLayout();
}

void PaneHeaderLayout::componentComplete() {
  QQuickItem::componentComplete();
  refreshLayout();
}

void PaneHeaderLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void PaneHeaderLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
