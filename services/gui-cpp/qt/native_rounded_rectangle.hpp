#pragma once

#include "ancestor_geometry.hpp"
#include <QColor>
#include <QQuickItem>
#include <QRectF>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <optional>

namespace telar::gui::qt {

class NativeRoundedRectangle : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(bool replaceBackground READ replaceBackground WRITE setReplaceBackground NOTIFY compositionChanged)
  Q_PROPERTY(QColor backdropColor READ backdropColor WRITE setBackdropColor NOTIFY compositionChanged)
  Q_PROPERTY(bool squareBottom READ squareBottom WRITE setSquareBottom NOTIFY compositionChanged)
  Q_PROPERTY(QColor borderColor READ borderColor WRITE setBorderColor NOTIFY borderColorChanged)
  Q_PROPERTY(qreal borderAlpha READ borderAlpha WRITE setBorderAlpha NOTIFY borderAlphaChanged)
  Q_PROPERTY(qreal radius READ radius WRITE setRadius NOTIFY radiusChanged)
  Q_PROPERTY(qreal borderWidth READ borderWidth WRITE setBorderWidth NOTIFY borderWidthChanged)
  Q_PROPERTY(QRectF paintClip READ paintClip WRITE setPaintClip RESET resetPaintClip NOTIFY paintClipChanged)

public:
  explicit NativeRoundedRectangle(QQuickItem *parent = nullptr);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] bool replaceBackground() const noexcept;
  void setReplaceBackground(bool replace);
  [[nodiscard]] QColor backdropColor() const;
  void setBackdropColor(const QColor &color);
  [[nodiscard]] bool squareBottom() const noexcept;
  void setSquareBottom(bool square);
  [[nodiscard]] QColor borderColor() const;
  void setBorderColor(const QColor &color);
  [[nodiscard]] qreal borderAlpha() const noexcept;
  void setBorderAlpha(qreal alpha);
  [[nodiscard]] qreal radius() const noexcept;
  void setRadius(qreal radius);
  [[nodiscard]] qreal borderWidth() const noexcept;
  void setBorderWidth(qreal width);
  [[nodiscard]] QRectF paintClip() const;
  void setPaintClip(const QRectF &bounds);
  void resetPaintClip();

signals:
  void colorChanged();
  void compositionChanged();
  void borderColorChanged();
  void borderAlphaChanged();
  void radiusChanged();
  void borderWidthChanged();
  void paintClipChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  QColor color_ = Qt::transparent;
  QColor border_color_ = Qt::transparent;
  QColor backdrop_color_ = Qt::transparent;
  bool replace_background_ = false;
  bool square_bottom_ = false;
  qreal radius_ = 0;
  qreal border_width_ = 0;
  float border_alpha_ = 1;
  AncestorGeometry ancestors_;
  std::optional<QRectF> paint_clip_;
};

}
