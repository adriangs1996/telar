#pragma once

#include "ancestor_geometry.hpp"
#include <QColor>
#include <QQuickItem>
#include <QRectF>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

class NativeRoundedRectangle : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(QColor borderColor READ borderColor WRITE setBorderColor NOTIFY borderColorChanged)
  Q_PROPERTY(qreal borderAlpha READ borderAlpha WRITE setBorderAlpha NOTIFY borderAlphaChanged)
  Q_PROPERTY(qreal radius READ radius WRITE setRadius NOTIFY radiusChanged)
  Q_PROPERTY(qreal borderWidth READ borderWidth WRITE setBorderWidth NOTIFY borderWidthChanged)

public:
  explicit NativeRoundedRectangle(QQuickItem *parent = nullptr);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] QColor borderColor() const;
  void setBorderColor(const QColor &color);
  [[nodiscard]] qreal borderAlpha() const noexcept;
  void setBorderAlpha(qreal alpha);
  [[nodiscard]] qreal radius() const noexcept;
  void setRadius(qreal radius);
  [[nodiscard]] qreal borderWidth() const noexcept;
  void setBorderWidth(qreal width);

signals:
  void colorChanged();
  void borderColorChanged();
  void borderAlphaChanged();
  void radiusChanged();
  void borderWidthChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  QColor color_ = Qt::transparent;
  QColor border_color_ = Qt::transparent;
  qreal radius_ = 0;
  qreal border_width_ = 0;
  float border_alpha_ = 1;
  AncestorGeometry ancestors_;
};

}
