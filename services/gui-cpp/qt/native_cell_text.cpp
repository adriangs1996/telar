#include "native_cell_text.hpp"
#include "cell_text_grid.hpp"
#include "chrome_text_scene.hpp"
#include "fonts/font_role.hpp"
#include "font_collection.hpp"
#include "resident_fonts.hpp"
#include "window_font_catalog.hpp"
#include <QByteArray>
#include <QColor>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>

namespace telar::gui::qt {

NativeCellText::NativeCellText(QQuickItem *parent)
    : QQuickItem(parent),
      layout_(memory_),
      ancestors_(*this) {
  setFlag(ItemHasContents);
}

QString NativeCellText::text() const {
  return text_;
}

QVariantMap NativeCellText::grid() const {
  return grid_;
}

QColor NativeCellText::color() const {
  return color_;
}

bool NativeCellText::bold() const noexcept {
  return bold_;
}

bool NativeCellText::available() const noexcept {
  return available_;
}

void NativeCellText::setText(const QString &text) {
  if (text_ != text) {
    text_ = text;
    invalidateLayout();
    emit textChanged();
  }
}

void NativeCellText::setGrid(const QVariantMap &grid) {
  if (grid_ != grid) {
    grid_ = grid;
    invalidateLayout();
    emit gridChanged();
  }
}

void NativeCellText::setColor(const QColor &color) {
  if (color_ != color) {
    color_ = color;
    update();
    emit colorChanged();
  }
}

void NativeCellText::setBold(bool bold) {
  if (bold_ != bold) {
    bold_ = bold;
    ++revision_;
    update();
    emit boldChanged();
  }
}

void NativeCellText::setAvailable(bool available) {
  if (available_ != available) {
    available_ = available;
    emit availabilityChanged();
  }
}

void NativeCellText::invalidateLayout() {
  layout_dirty_ = true;
  polish();
  update();
}

void NativeCellText::refreshLayout() {
  const QPointer<NativeCellText> alive{this};
  layout_dirty_ = false;
  try {
    scale_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    resolved_ = CellTextGrid::resolve(grid_, scale_);
    refreshFonts();
    const auto utf8 = text_.toUtf8();
    layout_.shape(*fonts_, {utf8.constData(), static_cast<std::size_t>(utf8.size())}, resolved_.metrics);
    setImplicitWidth((static_cast<qreal>(layout_.columns()) * resolved_.metrics.width) / scale_);
    if (!alive) {
      return;
    }

    setImplicitHeight(resolved_.metrics.height / scale_);
    if (!alive) {
      return;
    }

    setBaselineOffset(resolved_.metrics.baseline / scale_);
    if (!alive) {
      return;
    }

    ++revision_;
    if (catalog_) {
      catalog_->request({utf8.constData(), static_cast<std::size_t>(utf8.size())}, fonts::FontRole::primary, collection_);
    }

    setAvailable(true);
  } catch (const std::exception &) {
    if (alive) {
      setAvailable(false);
    }
  }

  if (alive) {
    update();
  }
}

void NativeCellText::refreshFonts() {
  auto *catalog = window() == nullptr ? nullptr : &WindowFontCatalog::forWindow(*window());
  if (catalog_ != catalog) {
    QObject::disconnect(catalog_connection_);
    catalog_ = catalog;
    if (catalog != nullptr) {
      catalog_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, &NativeCellText::invalidateLayout);
    }
  }

  const auto source = ResidentFonts::resolveSource(resolved_.family, resolved_.style);
  if (catalog != nullptr) {
    collection_ = catalog->collectionFor(source);
  } else if (!collection_ || collection_->primary != source) {
    collection_ = std::make_shared<const FontCollection>(FontCollection{.primary = source});
  }

  fonts_ = ResidentFonts::shared(collection_);
}

void NativeCellText::updatePolish() {
  if (layout_dirty_) {
    refreshLayout();
  }
}

void NativeCellText::componentComplete() {
  QQuickItem::componentComplete();
  refreshLayout();
}

void NativeCellText::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  ++revision_;
  update();
}

void NativeCellText::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
    update();
  }

  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    invalidateLayout();
  }
}

QSGNode *NativeCellText::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  if (window() == nullptr || !available_ || width() <= 0 || height() <= 0) {
    const std::unique_ptr<QSGNode> discarded{previous};

    return nullptr;
  }

  try {
    constexpr auto maximum_columns = std::numeric_limits<std::uint16_t>::max();
    const auto columns = static_cast<std::uint32_t>(std::clamp(std::floor(width() * scale_ / resolved_.metrics.width), qreal{0}, qreal{maximum_columns}));

    ChromeTextPaint paint;
    paint.glyphs = layout_.glyphs(columns);
    paint.spans = layout_.spans(columns);
    paint.grid = resolved_.metrics;
    paint.scene_origin = mapToScene({0, 0});
    paint.bounds = size();
    paint.color = color_;
    paint.scale = scale_;
    paint.revision = revision_;
    paint.pixel_height = resolved_.metrics.pixel_height;
    paint.role = fonts::FontRole::primary;
    paint.style.bold = bold_;

    return paintChromeText(previous, *window(), paint, collection_);
  } catch (const std::exception &) {
    QMetaObject::invokeMethod(this, [this] {
      setAvailable(false);
    },
                              Qt::QueuedConnection);

    return nullptr;
  }
}

}
