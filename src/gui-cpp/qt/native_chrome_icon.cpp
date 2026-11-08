#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "native_chrome_icon.hpp"
#include "chrome_icon_scene.hpp"
#include "../core/memory.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <concepts>
#include <utility>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "resident_fonts.hpp"
#include <QByteArray>
#include <QColor>
#include <QMetaObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QString>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <exception>

#include "core/memory.hpp"


import telar.gui.core.metrics;
import telar.gui.fonts.row_text_layout;

namespace telar::gui::qt {

NativeChromeIcon::NativeChromeIcon(QQuickItem *parent)
    : QQuickItem(parent),
      layout_(memory_),
      ancestors_(*this) {
  setFlag(ItemHasContents);
}

QString NativeChromeIcon::glyph() const {
  return glyph_;
}

QColor NativeChromeIcon::color() const {
  return color_;
}

qreal NativeChromeIcon::pixelSize() const noexcept {
  return pixel_size_;
}

QString NativeChromeIcon::primaryFamily() const {
  return primary_family_;
}

QString NativeChromeIcon::primaryStyle() const {
  return primary_style_;
}

bool NativeChromeIcon::available() const noexcept {
  return available_;
}

void NativeChromeIcon::setGlyph(const QString &glyph) {
  if (glyph_ != glyph) {
    glyph_ = glyph;
    emit glyphChanged();
    invalidateLayout();
  }
}

void NativeChromeIcon::setColor(const QColor &color) {
  if (color_ != color) {
    color_ = color;
    emit colorChanged();
    update();
  }
}

void NativeChromeIcon::setPixelSize(qreal size) {
  if (std::isfinite(size) && size > 0 && size <= ChromeMetrics::maximum_text && pixel_size_ != size) {
    pixel_size_ = size;
    emit pixelSizeChanged();
    invalidateLayout();
  }
}

void NativeChromeIcon::setPrimaryFamily(const QString &family) {
  if (primary_family_ != family) {
    primary_family_ = family;
    source_.reset();
    emit fontChanged();
    invalidateLayout();
  }
}

void NativeChromeIcon::setPrimaryStyle(const QString &style) {
  if (primary_style_ != style) {
    primary_style_ = style;
    source_.reset();
    emit fontChanged();
    invalidateLayout();
  }
}

void NativeChromeIcon::setAvailable(bool available) {
  if (available_ != available) {
    available_ = available;
    emit availabilityChanged();
  }
}

void NativeChromeIcon::invalidateLayout() {
  layout_dirty_ = true;
  polish();
  update();
}

void NativeChromeIcon::refreshLayout() {
  layout_dirty_ = false;
  try {
    if (!source_) {
      source_ = ResidentFonts::resolveSource(primary_family_, primary_style_);
    }

    fonts_ = ResidentFonts::shared(source_);
    display_scale_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    const auto pixels = std::clamp(std::round(static_cast<float>(pixel_size_ * display_scale_)), 1.0F, ChromeMetrics::maximum_text);
    using Layout = fonts::IconLayout<SystemAllocator>;
    pixel_height_ = static_cast<std::uint16_t>(std::min(pixels * Layout::oversample, static_cast<float>(Layout::maximum_pixel_height)));
    target_side_ = std::round(pixels * Layout::size_ratio);
    const auto utf8 = glyph_.toUtf8();
    layout_.shape(*fonts_, {utf8.constData(), static_cast<std::size_t>(utf8.size())}, {.pixel_height = pixel_height_});
    ++revision_;
    setAvailable(true);
  } catch (const std::exception &) {
    setAvailable(false);
  }

  update();
}

void NativeChromeIcon::updatePolish() {
  if (layout_dirty_) {
    refreshLayout();
  }
}

void NativeChromeIcon::componentComplete() {
  QQuickItem::componentComplete();
  refreshLayout();
}

void NativeChromeIcon::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  update();
}

void NativeChromeIcon::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
    update();
  }

  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    invalidateLayout();
  }
}

QSGNode *NativeChromeIcon::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  if (window() == nullptr || !available_ || width() <= 0 || height() <= 0) {
    const std::unique_ptr<QSGNode> discarded{previous};

    return nullptr;
  }

  try {
    return paintChromeIcon(previous, *window(), {.glyphs = layout_.glyphs(), .ink = layout_.ink(), .source = source_, .scene_origin = mapToScene({0, 0}), .bounds = size(), .color = color_, .scale = display_scale_, .target_side = target_side_, .pixel_height = pixel_height_, .revision = revision_});
  } catch (const std::exception &) {
    QMetaObject::invokeMethod(this, [this] {
      setAvailable(false);
    },
                              Qt::QueuedConnection);

    return nullptr;
  }
}

}
