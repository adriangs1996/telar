#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "ancestor_geometry.hpp"
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
#include "font_asset.hpp"
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
#include <QColor>
#include <QQuickItem>
#include <QSGNode>
#include <QString>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

#pragma once

#include "core/memory.hpp"


import telar.gui.core.metrics;
import telar.gui.fonts.row_text_layout;

namespace telar::gui::qt {

class NativeChromeIcon : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QString glyph READ glyph WRITE setGlyph NOTIFY glyphChanged)
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(qreal pixelSize READ pixelSize WRITE setPixelSize NOTIFY pixelSizeChanged)
  Q_PROPERTY(QString primaryFamily READ primaryFamily WRITE setPrimaryFamily NOTIFY fontChanged)
  Q_PROPERTY(QString primaryStyle READ primaryStyle WRITE setPrimaryStyle NOTIFY fontChanged)
  Q_PROPERTY(bool available READ available NOTIFY availabilityChanged)

public:
  explicit NativeChromeIcon(QQuickItem *parent = nullptr);
  [[nodiscard]] QString glyph() const;
  void setGlyph(const QString &glyph);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] qreal pixelSize() const noexcept;
  void setPixelSize(qreal size);
  [[nodiscard]] QString primaryFamily() const;
  void setPrimaryFamily(const QString &family);
  [[nodiscard]] QString primaryStyle() const;
  void setPrimaryStyle(const QString &style);
  [[nodiscard]] bool available() const noexcept;

signals:
  void glyphChanged();
  void colorChanged();
  void pixelSizeChanged();
  void fontChanged();
  void availabilityChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;

private:
  void invalidateLayout();
  void refreshLayout();
  void setAvailable(bool available);

  SystemAllocator memory_;
  fonts::IconLayout<SystemAllocator> layout_;
  tbc::view<AncestorGeometry, tbc::lt::self> ancestors_;
  std::shared_ptr<const FontAsset> source_;
  std::shared_ptr<ResidentFonts> fonts_;
  QString glyph_;
  QString primary_family_;
  QString primary_style_;
  QColor color_;
  qreal pixel_size_ = ChromeMetrics{}.body;
  qreal display_scale_ = 1;
  float target_side_ = 0;
  std::uint16_t pixel_height_ = 0;
  std::uint64_t revision_ = 0;
  bool available_ = false;
  bool layout_dirty_ = true;
};

}
