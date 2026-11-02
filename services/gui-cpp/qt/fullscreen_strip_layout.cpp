#include "fullscreen_strip_layout.hpp"
#include "application/pane_layout.hpp"
#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "font_collection.hpp"
#include "fonts/font_role.hpp"
#include "fonts/text_layout.hpp"
#include "pane_chrome_style.hpp"
#include "presentation/fullscreen_strip_geometry.hpp"
#include "projection.hpp"
#include "resident_fonts.hpp"
#include "window_font_catalog.hpp"
#include <QByteArray>
#include <QFont>
#include <QFontMetricsF>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

FullscreenStripLayout::FullscreenStripLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantList FullscreenStripLayout::entries() const {
  return entries_;
}

void FullscreenStripLayout::setEntries(const QVariantList &entries) {
  if (entries_ != entries) {
    entries_ = entries;
    emit entriesChanged();
    polish();
  }
}

QVariantMap FullscreenStripLayout::measurements() const {
  return measurements_;
}

void FullscreenStripLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    emit measurementsChanged();
    polish();
  }
}

qreal FullscreenStripLayout::ratio() const noexcept {
  return ratio_;
}

void FullscreenStripLayout::setRatio(qreal ratio) {
  if (std::isfinite(ratio) && ratio > 0 && ratio_ != ratio) {
    ratio_ = ratio;
    emit metricsChanged();
    polish();
  }
}

qreal FullscreenStripLayout::bandHeight() const noexcept {
  return band_height_;
}

void FullscreenStripLayout::setBandHeight(qreal height) {
  if (std::isfinite(height) && height >= 0 && band_height_ != height) {
    band_height_ = height;
    emit metricsChanged();
    polish();
  }
}

qreal FullscreenStripLayout::pixelSize() const noexcept {
  return pixel_size_;
}

void FullscreenStripLayout::setPixelSize(qreal size) {
  if (std::isfinite(size) && size > 0 && size <= ChromeMetrics::maximum_text && pixel_size_ != size) {
    pixel_size_ = size;
    emit metricsChanged();
    polish();
  }
}

QVariantList FullscreenStripLayout::items() const {
  return items_;
}

QRectF FullscreenStripLayout::chipBounds() const noexcept {
  return chip_;
}

QRectF FullscreenStripLayout::progressBounds() const noexcept {
  return progress_;
}

QRectF FullscreenStripLayout::leaveBounds() const noexcept {
  return leave_;
}

bool FullscreenStripLayout::compactProgress() const noexcept {
  return compact_progress_;
}

bool FullscreenStripLayout::named() const noexcept {
  return named_;
}

QVariantMap FullscreenStripLayout::style() const {
  return paneChromeStyle(ratio_, density_);
}

QRectF FullscreenStripLayout::logical(Rect bounds) const noexcept {
  return toQRectF(bounds, density_);
}

void FullscreenStripLayout::refreshFonts() {
  auto *catalog = window() == nullptr ? nullptr : &WindowFontCatalog::forWindow(*window());
  if (catalog_ != catalog) {
    QObject::disconnect(catalog_connection_);
    catalog_ = catalog;
    if (catalog != nullptr) {
      catalog_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, &QQuickItem::polish);
    }
  }

  if (catalog != nullptr) {
    collection_ = catalog->collection();
  } else if (!collection_) {
    collection_ = std::make_shared<const FontCollection>(FontCollection{.primary = ResidentFonts::resolveSource({}, {})});
  }

  fonts_ = ResidentFonts::shared(collection_);
}

float FullscreenStripLayout::advance(const QString &text, fonts::FontRole role) {
  const auto pixels = static_cast<std::uint16_t>(std::clamp(std::round(pixel_size_ * density_), qreal{1}, static_cast<qreal>(ChromeMetrics::maximum_text)));
  try {
    if (fonts_) {
      const auto utf8 = text.toUtf8();
      const std::string_view label{utf8.constData(), static_cast<std::size_t>(utf8.size())};
      const auto width = fonts::TextLayout<SystemAllocator>::measure(*fonts_, label, {.pixel_height = pixels, .preferred = role});
      if (catalog_) {
        catalog_->request(label, role);
      }

      return static_cast<float>(width);
    }
  } catch (const std::exception &) {
    fonts_.reset();
  }

  QFont font{QStringLiteral("IBM Plex Sans")};
  font.setPixelSize(pixels);
  font.setWeight(role == fonts::FontRole::emphasized ? QFont::DemiBold : QFont::Normal);

  return static_cast<float>(QFontMetricsF{font}.horizontalAdvance(text));
}

void FullscreenStripLayout::refreshLayout() {
  const auto density = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  if (density_ != density) {
    density_ = density;
    emit metricsChanged();
  }

  try {
    refreshFonts();
  } catch (const std::exception &) {
    fonts_.reset();
  }

  std::array<FullscreenEntryMeasure, PaneLayout::maximum_panes> sizes{};
  const auto count = std::min(static_cast<std::size_t>(entries_.size()), sizes.size());
  for (std::size_t index = 0; index < count; ++index) {
    const auto entry = entries_[static_cast<qsizetype>(index)].toMap();
    const auto focused = entry.value(QStringLiteral("focused")).toBool();
    sizes[index] = {.index = advance(entry.value(QStringLiteral("index")).toString(), focused ? fonts::FontRole::emphasized : fonts::FontRole::regular), .name = advance(entry.value(QStringLiteral("program")).toString(), fonts::FontRole::regular), .focused = focused, .attention = !entry.value(QStringLiteral("attentionColor")).toString().isEmpty()};
  }

  const auto measured = [&](const QString &name) {
    const auto value = measurements_.value(name).toDouble();

    return std::isfinite(value) && value > 0 ? static_cast<float>(value * density_) : 0;
  };
  constexpr qreal mark_size_ratio = 0.85;
  const auto body_pixels = std::clamp(std::round(pixel_size_ * density_), qreal{1}, static_cast<qreal>(ChromeMetrics::maximum_text));
  const FullscreenStripMetrics metrics{.ratio = static_cast<float>(ratio_ * density_), .maximum_band_height = static_cast<float>(band_height_ * density_), .mark_side = static_cast<float>(std::round(body_pixels * mark_size_ratio))};
  const auto plan = FullscreenStripGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, metrics, std::span{sizes}.first(count), {.chip = measured(QStringLiteral("chip")), .progress = measured(QStringLiteral("progress")), .compact_progress = measured(QStringLiteral("compactProgress"))});
  QVariantList items;
  items.reserve(static_cast<qsizetype>(plan.count));
  for (const auto &entry : std::span{plan.entries}.first(plan.count)) {
    const auto bounds = logical(entry.bounds);
    const auto local = [&](Rect part) {
      return logical(part).translated(-bounds.topLeft());
    };
    items.append(QVariantMap{
        {QStringLiteral("entry"), entries_[static_cast<qsizetype>(entry.source)]},
        {QStringLiteral("bounds"), bounds},
        {QStringLiteral("mark"), local(entry.mark)},
        {QStringLiteral("index"), local(entry.index)},
        {QStringLiteral("name"), local(entry.name)},
        {QStringLiteral("attention"), local(entry.attention)},
    });
  }

  const auto chip = logical(plan.chip);
  const auto progress = logical(plan.progress);
  const auto leave = logical(plan.leave);
  if (items_ != items || chip_ != chip || progress_ != progress || leave_ != leave || named_ != plan.named || compact_progress_ != plan.compact_progress) {
    items_ = std::move(items);
    chip_ = chip;
    progress_ = progress;
    leave_ = leave;
    named_ = plan.named;
    compact_progress_ = plan.compact_progress;
    emit layoutChanged();
  }
}

void FullscreenStripLayout::updatePolish() {
  refreshLayout();
}

void FullscreenStripLayout::componentComplete() {
  QQuickItem::componentComplete();
  refreshLayout();
}

void FullscreenStripLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void FullscreenStripLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
