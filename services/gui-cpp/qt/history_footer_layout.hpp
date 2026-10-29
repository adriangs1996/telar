#pragma once

#include "core/geometry.hpp"
#include "presentation/history_footer_geometry.hpp"
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class HistoryFooterLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QVariantList hints READ hints NOTIFY labelsChanged)
  Q_PROPERTY(QString range READ range NOTIFY labelsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  explicit HistoryFooterLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap input() const;
  void setInput(const QVariantMap &input);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QVariantList hints() const;
  [[nodiscard]] QString range() const;
  [[nodiscard]] QVariantMap layout() const;

signals:
  void inputChanged();
  void measurementsChanged();
  void labelsChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  void prepareLabels();
  [[nodiscard]] QRectF logical(Rect area) const noexcept;

  QVariantMap input_;
  QVariantMap measurements_;
  QVariantList hints_;
  QString range_;
  HistoryFooterGeometry geometry_;
  qreal density_ = 1;
  qreal ratio_ = 1;
};

}
