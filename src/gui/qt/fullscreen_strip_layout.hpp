#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include "font_collection.hpp"
#include <concepts>
#include <utility>
#include "resident_fonts.hpp"
#include "window_font_catalog.hpp"
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <memory>

#pragma once


import telar.gui.core.metrics;
import telar.gui.fonts.face;

namespace telar::gui::qt {

class FullscreenStripLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantList entries READ entries WRITE setEntries NOTIFY entriesChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY metricsChanged)
  Q_PROPERTY(qreal bandHeight READ bandHeight WRITE setBandHeight NOTIFY metricsChanged)
  Q_PROPERTY(qreal pixelSize READ pixelSize WRITE setPixelSize NOTIFY metricsChanged)
  Q_PROPERTY(QVariantList items READ items NOTIFY layoutChanged)
  Q_PROPERTY(QRectF chipBounds READ chipBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF progressBounds READ progressBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF leaveBounds READ leaveBounds NOTIFY layoutChanged)
  Q_PROPERTY(bool compactProgress READ compactProgress NOTIFY layoutChanged)
  Q_PROPERTY(bool named READ named NOTIFY layoutChanged)
  Q_PROPERTY(QVariantMap style READ style NOTIFY metricsChanged)

public:
  explicit FullscreenStripLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantList entries() const;
  void setEntries(const QVariantList &entries);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] qreal bandHeight() const noexcept;
  void setBandHeight(qreal height);
  [[nodiscard]] qreal pixelSize() const noexcept;
  void setPixelSize(qreal size);
  [[nodiscard]] QVariantList items() const;
  [[nodiscard]] QRectF chipBounds() const noexcept;
  [[nodiscard]] QRectF progressBounds() const noexcept;
  [[nodiscard]] QRectF leaveBounds() const noexcept;
  [[nodiscard]] bool compactProgress() const noexcept;
  [[nodiscard]] bool named() const noexcept;
  [[nodiscard]] QVariantMap style() const;

signals:
  void entriesChanged();
  void measurementsChanged();
  void metricsChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  void refreshFonts();
  void refreshLayout();
  [[nodiscard]] float advance(const QString &text, fonts::FontRole role);
  [[nodiscard]] QRectF logical(Rect bounds) const noexcept;

  QVariantList entries_;
  QVariantMap measurements_;
  QVariantList items_;
  QRectF chip_;
  QRectF progress_;
  QRectF leave_;
  qreal ratio_ = 1;
  qreal band_height_ = ChromeMetrics::logical_pane_header;
  qreal pixel_size_ = ChromeMetrics{}.body;
  qreal density_ = 1;
  bool compact_progress_ = false;
  bool named_ = true;
  QPointer<WindowFontCatalog> catalog_;
  QMetaObject::Connection catalog_connection_;
  std::shared_ptr<const FontCollection> collection_;
  std::shared_ptr<ResidentFonts> fonts_;
};

}
