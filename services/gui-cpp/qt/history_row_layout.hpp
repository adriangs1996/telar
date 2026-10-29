#pragma once

#include "core/geometry.hpp"
#include "presentation/history_card.hpp"
#include "presentation/history_match_highlight.hpp"
#include "presentation/history_row_geometry.hpp"
#include <QByteArray>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <string_view>

namespace telar::gui::qt {

class HistoryRowLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  explicit HistoryRowLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] Rect physicalFrame() const noexcept;

signals:
  void measurementsChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  [[nodiscard]] QRectF logical(Rect area) const noexcept;
  [[nodiscard]] QVariantList commandLines() const;
  [[nodiscard]] QVariantMap commandLine(std::string_view text, Rect bounds, bool continues, HistoryMatchHighlight &highlight) const;
  void prepareCommand();

  QVariantMap measurements_;
  QString command_text_;
  QByteArray command_bytes_;
  HistoryRowGeometry geometry_;
  HistoryCard card_;
  qreal density_ = 1;
  qreal ratio_ = 1;
  float command_width_ = 0;
  float cell_width_ = 1;
  float cell_height_ = 1;
  std::uint32_t first_line_columns_ = 0;
  bool measurements_dirty_ = true;
  bool expanded_ = false;
};

}
