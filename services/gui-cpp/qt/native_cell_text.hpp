#pragma once

#include "ancestor_geometry.hpp"
#include "cell_text_grid.hpp"
#include "core/memory.hpp"
#include "font_collection.hpp"
#include "fonts/cell_text_layout.hpp"
#include <QColor>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QSGNode>
#include <QString>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <memory>

namespace telar::gui::qt {

class ResidentFonts;
class WindowFontCatalog;

class NativeCellText : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QString text READ text WRITE setText NOTIFY textChanged)
  Q_PROPERTY(QVariantMap grid READ grid WRITE setGrid NOTIFY gridChanged)
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(bool bold READ bold WRITE setBold NOTIFY boldChanged)
  Q_PROPERTY(bool available READ available NOTIFY availabilityChanged)

public:
  explicit NativeCellText(QQuickItem *parent = nullptr);
  [[nodiscard]] QString text() const;
  void setText(const QString &text);
  [[nodiscard]] QVariantMap grid() const;
  void setGrid(const QVariantMap &grid);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] bool bold() const noexcept;
  void setBold(bool bold);
  [[nodiscard]] bool available() const noexcept;

signals:
  void textChanged();
  void gridChanged();
  void colorChanged();
  void boldChanged();
  void availabilityChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;

private:
  static constexpr std::size_t maximum_text_bytes = 8192;
  void invalidateLayout();
  void refreshLayout();
  void refreshFonts();
  void setAvailable(bool available);

  SystemAllocator memory_;
  fonts::CellTextLayout<SystemAllocator, maximum_text_bytes> layout_;
  AncestorGeometry ancestors_;
  std::shared_ptr<const FontCollection> collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  QPointer<WindowFontCatalog> catalog_;
  QMetaObject::Connection catalog_connection_;
  CellTextGrid resolved_;
  QVariantMap grid_;
  QString text_;
  QColor color_;
  qreal scale_ = 1;
  std::uint64_t revision_ = 0;
  bool bold_ = false;
  bool available_ = false;
  bool layout_dirty_ = true;
};

}
