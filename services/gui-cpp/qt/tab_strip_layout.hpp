#pragma once

#include "chrome_fonts.hpp"
#include "list_model.hpp"
#include <QAbstractItemModel>
#include <QFont>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstddef>
#include <memory>

namespace telar::gui::qt {

class TabStripLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QAbstractItemModel *model READ model WRITE setModel NOTIFY modelChanged)
  Q_PROPERTY(QAbstractItemModel *items READ items CONSTANT)
  Q_PROPERTY(QFont font READ font WRITE setFont NOTIFY fontChanged)
  Q_PROPERTY(qreal pixelSize READ pixelSize WRITE setPixelSize NOTIFY fontChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(bool hovered READ hovered WRITE setHovered NOTIFY hoveredChanged)
  Q_PROPERTY(QRectF plus READ plus NOTIFY layoutChanged)
  Q_PROPERTY(QVariantMap counter READ counter NOTIFY layoutChanged)
  Q_PROPERTY(QVariantMap style READ style NOTIFY ratioChanged)

public:
  explicit TabStripLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QAbstractItemModel *model() const noexcept;
  void setModel(QAbstractItemModel *model);
  [[nodiscard]] QAbstractItemModel *items() noexcept;
  [[nodiscard]] QFont font() const;
  void setFont(const QFont &font);
  [[nodiscard]] qreal pixelSize() const noexcept;
  void setPixelSize(qreal size);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] bool hovered() const noexcept;
  void setHovered(bool hovered);
  [[nodiscard]] QRectF plus() const noexcept;
  [[nodiscard]] QVariantMap counter() const;
  [[nodiscard]] QVariantMap style() const;

signals:
  void modelChanged();
  void fontChanged();
  void ratioChanged();
  void hoveredChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  static constexpr std::size_t model_connection_count = 6;
  [[nodiscard]] float captionAdvance(const QString &label);
  void rebuild();

  QPointer<QAbstractItemModel> model_;
  std::array<QMetaObject::Connection, model_connection_count> connections_;
  ListModel items_{this};
  QFont font_;
  std::shared_ptr<ChromeFonts> fonts_;
  qreal pixel_size_ = 0;
  qreal ratio_ = 1;
  bool hovered_ = false;
  QString anchor_;
  QRectF plus_;
  QVariantMap counter_;
};

}
