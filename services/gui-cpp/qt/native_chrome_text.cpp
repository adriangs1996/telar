#include "native_chrome_text.hpp"
#include "chrome_text_scene.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "font_collection.hpp"
#include "fonts/font_role.hpp"
#include "fonts/shaped_run_view.hpp"
#include "fonts/text_layout.hpp"
#include "resident_fonts.hpp"
#include "text/text_fit.hpp"
#include "window_font_catalog.hpp"
#include <QByteArray>
#include <QColor>
#include <QMetaObject>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QString>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <string_view>

namespace telar::gui::qt {

NativeChromeText::NativeChromeText(QQuickItem *parent)
    : QQuickItem(parent),
      glyphs_(memory_),
      fitted_glyphs_(memory_),
      ancestors_(*this) {
  setFlag(ItemHasContents);
}

QString NativeChromeText::text() const {
  return text_;
}

qreal NativeChromeText::pixelSize() const noexcept {
  return pixel_size_;
}

QColor NativeChromeText::color() const {
  return color_;
}

qreal NativeChromeText::fadeWidth() const noexcept {
  return fade_width_;
}

bool NativeChromeText::emphasized() const noexcept {
  return emphasized_;
}

bool NativeChromeText::caption() const noexcept {
  return caption_;
}

void NativeChromeText::setCaption(bool caption) {
  if (caption_ != caption) {
    caption_ = caption;
    emit layoutChanged();
    invalidateLayout();
  }
}

int NativeChromeText::elide() const noexcept {
  return elide_;
}

int NativeChromeText::horizontalAlignment() const noexcept {
  return static_cast<int>(alignment_.toInt());
}

bool NativeChromeText::wholePixelCentering() const noexcept {
  return whole_pixel_centering_;
}

bool NativeChromeText::supported() const noexcept {
  return supported_;
}

bool NativeChromeText::available() const noexcept {
  return available_;
}

void NativeChromeText::refreshAvailability() {
  const auto available = supported_ && !render_failed_ && (elide_ == Qt::ElideNone || elide_ == Qt::ElideRight);
  if (available_ != available) {
    available_ = available;
    emit availabilityChanged();
    update();
  }
}

void NativeChromeText::setSupported(bool supported) {
  if (supported_ != supported) {
    supported_ = supported;
    emit supportChanged();
  }
}

void NativeChromeText::setText(const QString &text) {
  if (text_ != text) {
    text_ = text;
    emit textChanged();
    invalidateLayout();
  }
}

void NativeChromeText::setPixelSize(qreal size) {
  if (std::isfinite(size) && size > 0 && size <= ChromeMetrics::maximum_text && pixel_size_ != size) {
    pixel_size_ = size;
    emit pixelSizeChanged();
    invalidateLayout();
  }
}

void NativeChromeText::setColor(const QColor &color) {
  if (color_ != color) {
    color_ = color;
    emit colorChanged();
    update();
  }
}

void NativeChromeText::setEmphasized(bool emphasized) {
  if (emphasized_ != emphasized) {
    emphasized_ = emphasized;
    emit emphasizedChanged();
    invalidateLayout();
  }
}

void NativeChromeText::setFadeWidth(qreal width) {
  if (std::isfinite(width) && width >= 0 && fade_width_ != width) {
    fade_width_ = width;
    emit layoutChanged();
    update();
  }
}

void NativeChromeText::setElide(int elide) {
  const auto mode = static_cast<Qt::TextElideMode>(elide);
  if (elide_ != mode) {
    elide_ = mode;
    fit_dirty_ = true;
    emit layoutChanged();
    polish();
    update();
  }
}

void NativeChromeText::setHorizontalAlignment(int alignment) {
  const auto value = Qt::Alignment::fromInt(alignment);
  if (alignment_ != value) {
    alignment_ = value;
    emit layoutChanged();
    update();
  }
}

void NativeChromeText::setWholePixelCentering(bool enabled) {
  if (whole_pixel_centering_ != enabled) {
    whole_pixel_centering_ = enabled;
    emit layoutChanged();
    update();
  }
}

void NativeChromeText::invalidateLayout() {
  layout_dirty_ = true;
  render_failed_ = false;
  polish();
  update();
}

void NativeChromeText::refreshLayout() {
  layout_dirty_ = false;
  display_scale_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  pixel_height_ = static_cast<std::uint16_t>(std::clamp(std::round(static_cast<float>(pixel_size_ * display_scale_)), 1.0F, ChromeMetrics::maximum_text));
  try {
    refreshFonts();
    const auto preferred = emphasized_ ? fonts::FontRole::emphasized : fonts::FontRole::regular;
    utf8_ = text_.toUtf8();
    const std::string_view text{utf8_.constData(), static_cast<std::size_t>(utf8_.size())};
    if (caption_) {
      glyphs_.shapeCaption(*fonts_, text, {.pixel_height = pixel_height_, .preferred = preferred});
    } else {
      glyphs_.shape(*fonts_, text, {.pixel_height = pixel_height_, .preferred = preferred});
    }
    advance_ = glyphs_.advance();
    metrics_ = fonts_->face(preferred).metrics(pixel_height_);
    setSupported(true);
    setImplicitWidth(advance_ / display_scale_);
    setImplicitHeight(metrics_.line_height / display_scale_);
    setBaselineOffset(metrics_.ascender / display_scale_);
    ++revision_;
    fit_dirty_ = true;
    fit_shape_dirty_ = true;
    if (catalog_ != nullptr) {
      catalog_->request(text, preferred);
    }
  } catch (const std::exception &) {
    setSupported(false);
  }

  refreshFit();
  update();
}

void NativeChromeText::refreshFonts() {
  auto *catalog = window() == nullptr ? nullptr : &WindowFontCatalog::forWindow(*window());
  if (catalog_ != catalog) {
    QObject::disconnect(catalog_connection_);
    catalog_ = catalog;
    if (catalog != nullptr) {
      catalog_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, &NativeChromeText::invalidateLayout);
    }
  }

  if (catalog != nullptr) {
    collection_ = catalog->collection();
  } else if (!collection_) {
    collection_ = std::make_shared<const FontCollection>(FontCollection{.primary = ResidentFonts::resolveSource({}, {})});
  }

  fonts_ = ResidentFonts::shared(collection_);
}

void NativeChromeText::refreshFit() {
  fit_dirty_ = false;
  fitted_ = supported_ && elide_ == Qt::ElideRight && static_cast<float>(width() * display_scale_) < static_cast<float>(advance_);
  try {
    if (fitted_) {
      const std::string_view text{utf8_.constData(), static_cast<std::size_t>(utf8_.size())};
      const auto measure = [&](std::string_view label) {
        return static_cast<float>(label == text ? advance_ : fonts::TextLayout<SystemAllocator>::measure(*fonts_, label, {.pixel_height = pixel_height_, .preferred = emphasized_ ? fonts::FontRole::emphasized : fonts::FontRole::regular}));
      };
      TextFit::Buffer buffer{};
      const auto fitted = TextFit::fit(text, static_cast<float>(width() * display_scale_), measure, buffer);
      shapeFittedText(fitted);
    }

    ++revision_;
  } catch (const std::exception &) {
    render_failed_ = true;
  }

  refreshAvailability();
}

void NativeChromeText::shapeFittedText(std::string_view text) {
  if (!fit_shape_dirty_ && text == std::string_view{fitted_text_.data(), fitted_bytes_}) {
    return;
  }

  fitted_glyphs_.shape(*fonts_, text, {.pixel_height = pixel_height_, .preferred = emphasized_ ? fonts::FontRole::emphasized : fonts::FontRole::regular});
  fitted_advance_ = fitted_glyphs_.advance();
  std::ranges::copy(text, fitted_text_.begin());
  fitted_bytes_ = text.size();
  fit_shape_dirty_ = false;
}

void NativeChromeText::updatePolish() {
  if (layout_dirty_) {
    refreshLayout();
  } else if (fit_dirty_) {
    refreshFit();
  } else {
    refreshAvailability();
  }
}

void NativeChromeText::componentComplete() {
  QQuickItem::componentComplete();
  refreshLayout();
}

void NativeChromeText::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  if (current.width() != previous.width()) {
    fit_dirty_ = true;
  }

  polish();
  update();
}

void NativeChromeText::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
    update();
  }

  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    invalidateLayout();
  }
}

QSGNode *NativeChromeText::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  if (window() == nullptr || !available() || width() <= 0 || height() <= 0) {
    const std::unique_ptr<QSGNode> discarded{previous};

    return nullptr;
  }

  try {
    const auto &layout = fitted_ ? fitted_glyphs_ : glyphs_;

    return paintChromeText(previous, *window(), {.glyphs = layout.glyphs(), .spans = layout.spans(), .metrics = metrics_, .scene_origin = mapToScene({0, 0}), .bounds = size(), .color = color_, .scale = display_scale_, .fade_width = fade_width_, .revision = revision_, .pixel_height = pixel_height_, .advance = fitted_ ? fitted_advance_ : advance_, .horizontal_alignment = alignment_, .whole_pixel_centering = whole_pixel_centering_, .emphasized = emphasized_}, collection_);
  } catch (const std::exception &) {
    QMetaObject::invokeMethod(this, [this] {
      render_failed_ = true;
      refreshAvailability();
    },
                              Qt::QueuedConnection);

    return nullptr;
  }
}

}
