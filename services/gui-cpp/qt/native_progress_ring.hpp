#pragma once

#include "tbc/view.hpp"
#include "ancestor_geometry.hpp"
#include <QColor>
#include <QQuickItem>
#include <QRectF>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class NativeProgressRing : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(qreal fraction READ fraction WRITE setFraction NOTIFY fractionChanged)
  Q_PROPERTY(qreal turns READ turns WRITE setTurns NOTIFY turnsChanged)

public:
  explicit NativeProgressRing(QQuickItem *parent = nullptr);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] qreal fraction() const noexcept;
  void setFraction(qreal fraction);
  [[nodiscard]] qreal turns() const noexcept;
  void setTurns(qreal turns);

signals:
  void colorChanged();
  void fractionChanged();
  void turnsChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;

private:
  QColor color_ = Qt::white;
  qreal fraction_ = 0;
  qreal turns_ = 0;
  tbc::view<AncestorGeometry, tbc::lt::self> ancestors_;
};

}
