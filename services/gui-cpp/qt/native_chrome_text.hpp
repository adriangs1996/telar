#pragma once

#include "ancestor_geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "font_collection.hpp"
#include "fonts/text_layout.hpp"
#include "resident_fonts.hpp"
#include "terminal/font_grid.hpp"
#include "text/text_fit.hpp"
#include <QByteArray>
#include <QColor>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string_view>

namespace telar::gui::qt {

class WindowFontCatalog;

class NativeChromeText : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QString text READ text WRITE setText NOTIFY textChanged)
  Q_PROPERTY(qreal pixelSize READ pixelSize WRITE setPixelSize NOTIFY pixelSizeChanged)
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(qreal fadeWidth READ fadeWidth WRITE setFadeWidth NOTIFY layoutChanged)
  Q_PROPERTY(bool emphasized READ emphasized WRITE setEmphasized NOTIFY emphasizedChanged)
  Q_PROPERTY(bool caption READ caption WRITE setCaption NOTIFY layoutChanged)
  Q_PROPERTY(int elide READ elide WRITE setElide NOTIFY layoutChanged)
  Q_PROPERTY(int horizontalAlignment READ horizontalAlignment WRITE setHorizontalAlignment NOTIFY layoutChanged)
  Q_PROPERTY(bool supported READ supported NOTIFY supportChanged)
  Q_PROPERTY(bool available READ available NOTIFY availabilityChanged)

public:
  explicit NativeChromeText(QQuickItem *parent = nullptr);
  [[nodiscard]] QString text() const;
  void setText(const QString &text);
  [[nodiscard]] qreal pixelSize() const noexcept;
  void setPixelSize(qreal size);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] qreal fadeWidth() const noexcept;
  void setFadeWidth(qreal width);
  [[nodiscard]] bool emphasized() const noexcept;
  void setEmphasized(bool emphasized);
  [[nodiscard]] bool caption() const noexcept;
  void setCaption(bool caption);
  [[nodiscard]] int elide() const noexcept;
  void setElide(int elide);
  [[nodiscard]] int horizontalAlignment() const noexcept;
  void setHorizontalAlignment(int alignment);
  [[nodiscard]] bool supported() const noexcept;
  [[nodiscard]] bool available() const noexcept;

signals:
  void textChanged();
  void pixelSizeChanged();
  void colorChanged();
  void emphasizedChanged();
  void layoutChanged();
  void availabilityChanged();
  void supportChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;

private:
  void invalidateLayout();
  void refreshLayout();
  void refreshFit();
  void shapeFittedText(std::string_view text);
  void refreshAvailability();
  void setSupported(bool supported);
  void refreshFonts();

  SystemAllocator memory_;
  fonts::TextLayout<SystemAllocator> glyphs_;
  fonts::TextLayout<SystemAllocator> fitted_glyphs_;
  AncestorGeometry ancestors_;
  std::shared_ptr<ResidentFonts> fonts_;
  std::shared_ptr<const FontCollection> collection_;
  QPointer<WindowFontCatalog> catalog_;
  QMetaObject::Connection catalog_connection_;
  QString text_;
  QByteArray utf8_;
  TextFit::Buffer fitted_text_{};
  QColor color_;
  FontMetrics metrics_;
  qreal pixel_size_ = ChromeMetrics{}.body;
  qreal display_scale_ = 1;
  qreal fade_width_ = 0;
  std::uint64_t revision_ = 0;
  std::int32_t advance_ = 0;
  std::int32_t fitted_advance_ = 0;
  std::size_t fitted_bytes_ = 0;
  std::uint16_t pixel_height_ = 0;
  Qt::TextElideMode elide_ = Qt::ElideRight;
  Qt::Alignment alignment_ = Qt::AlignLeft;
  bool emphasized_ = false;
  bool caption_ = false;
  bool supported_ = false;
  bool available_ = false;
  bool layout_dirty_ = true;
  bool fit_dirty_ = true;
  bool fit_shape_dirty_ = true;
  bool fitted_ = false;
  bool render_failed_ = false;
};

}
