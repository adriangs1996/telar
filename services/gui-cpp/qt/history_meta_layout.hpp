#pragma once

#include "core/geometry.hpp"
#include "input/history_action_capture.hpp"
#include "presentation/history_meta_geometry.hpp"
#include <QQuickItem>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class HistoryMetaLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QVariantList facts READ facts NOTIFY labelsChanged)
  Q_PROPERTY(QVariantList actions READ actions NOTIFY labelsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  explicit HistoryMetaLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap input() const;
  void setInput(const QVariantMap &input);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QVariantList facts() const;
  [[nodiscard]] QVariantList actions() const;
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] HistoryActionSurface actionSurface(std::uint64_t generation) const;

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
  QVariantList facts_;
  QVariantList actions_;
  HistoryMetaGeometry geometry_;
  qreal density_ = 1;
  qreal ratio_ = 1;
};

}
