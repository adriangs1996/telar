#pragma once

#include <QQuickItem>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

// Lays out the mode bar: QML measures the badge and hint texts it shows, this places them.
class NativeModeLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap mode READ mode WRITE setMode NOTIFY modeChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(qreal pixelSize READ pixelSize WRITE setPixelSize NOTIFY pixelSizeChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QString title READ title NOTIFY labelsChanged)
  Q_PROPERTY(QVariantList hints READ hints NOTIFY labelsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  explicit NativeModeLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap mode() const;
  void setMode(const QVariantMap &mode);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] qreal pixelSize() const noexcept;
  void setPixelSize(qreal pixelSize);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QString title() const;
  [[nodiscard]] QVariantList hints() const;
  [[nodiscard]] QVariantMap layout() const;

signals:
  void modeChanged();
  void ratioChanged();
  void pixelSizeChanged();
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
  void refreshLayout();

  QVariantMap mode_;
  QVariantMap measurements_;
  QString title_;
  QVariantList hints_;
  QVariantMap layout_;
  qreal ratio_ = 1;
  qreal pixel_size_ = 0;
};

}
