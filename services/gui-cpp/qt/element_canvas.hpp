#pragma once

#include <QColor>
#include <QPainterPath>
#include <QQuickPaintedItem>
#include <QString>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

// Draws a mod's vector operations. The list arrives already validated and with its colours
// resolved; the item repaints only when the list or its size changes, never per frame.
class ElementCanvas : public QQuickPaintedItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantList operations READ operations WRITE setOperations NOTIFY operationsChanged)
  // Operations use logical pixels; the item scales them to its own.
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY operationsChanged)

public:
  enum Operation : int {
    op_move,
    op_line,
    op_curve,
    op_quad,
    op_arc,
    op_rect,
    op_round_rect,
    op_circle,
    op_path,
    op_close,
    op_fill,
    op_stroke,
    op_width,
    op_cap,
    op_join,
    op_alpha,
    op_translate,
    op_rotate,
    op_scale,
    op_save,
    op_restore,
  };
  Q_ENUM(Operation)

  explicit ElementCanvas(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantList operations() const;
  void setOperations(const QVariantList &operations);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  void paint(QPainter *painter) override;

  // Parses the SVG path subset M L H V C Q Z, absolute and relative; anything else stops it.
  [[nodiscard]] static bool appendSvgPath(QPainterPath &path, const QString &data);

signals:
  void operationsChanged();

private:
  QVariantList operations_;
  qreal ratio_ = 1;
};

}
