#pragma once

#include "core/metrics.hpp"
#include "presentation/pane_chrome.hpp"
#include <QQuickItem>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class PaneHeaderLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY metricsChanged)
  Q_PROPERTY(qreal bandHeight READ bandHeight WRITE setBandHeight NOTIFY metricsChanged)
  Q_PROPERTY(QVariantMap style READ style NOTIFY metricsChanged)
  Q_PROPERTY(QRectF indexBounds READ indexBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF nameBounds READ nameBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF pausedBounds READ pausedBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF chipBounds READ chipBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF progressBounds READ progressBounds NOTIFY layoutChanged)
  Q_PROPERTY(bool compactProgress READ compactProgress NOTIFY layoutChanged)

public:
  explicit PaneHeaderLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] qreal bandHeight() const noexcept;
  void setBandHeight(qreal height);
  [[nodiscard]] QVariantMap style() const;
  [[nodiscard]] QRectF indexBounds() const noexcept;
  [[nodiscard]] QRectF nameBounds() const noexcept;
  [[nodiscard]] QRectF pausedBounds() const noexcept;
  [[nodiscard]] QRectF chipBounds() const noexcept;
  [[nodiscard]] QRectF progressBounds() const noexcept;
  [[nodiscard]] bool compactProgress() const noexcept;

signals:
  void measurementsChanged();
  void metricsChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  [[nodiscard]] QRectF logical(Rect bounds) const noexcept;
  void refreshLayout();

  QVariantMap measurements_;
  PaneHeaderGeometry layout_;
  qreal ratio_ = 1;
  qreal band_height_ = ChromeMetrics::logical_pane_header;
  qreal density_ = 1;
};

}
