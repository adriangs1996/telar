#pragma once

#include <QQuickItem>
#include <QRectF>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class NativeModeLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap mode READ mode WRITE setMode NOTIFY modeChanged)
  Q_PROPERTY(QVariantMap grid READ grid WRITE setGrid NOTIFY gridChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(QVariantList labels READ labels NOTIFY layoutChanged)
  Q_PROPERTY(QRectF chip READ chip NOTIFY layoutChanged)
  Q_PROPERTY(qreal chipRadius READ chipRadius NOTIFY ratioChanged)

public:
  explicit NativeModeLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap mode() const;
  void setMode(const QVariantMap &mode);
  [[nodiscard]] QVariantMap grid() const;
  void setGrid(const QVariantMap &grid);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] QVariantList labels() const;
  [[nodiscard]] QRectF chip() const noexcept;
  [[nodiscard]] qreal chipRadius() const noexcept;

signals:
  void modeChanged();
  void gridChanged();
  void ratioChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  void refreshLayout();

  QVariantMap mode_;
  QVariantMap grid_;
  QVariantList labels_;
  QRectF chip_;
  qreal ratio_ = 1;
};

}
