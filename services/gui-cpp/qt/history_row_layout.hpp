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
  Q_PROPERTY(QVariantMap geometryLayout READ geometryLayout NOTIFY geometryLayoutChanged)
  Q_PROPERTY(QVariantList lineLayout READ commandLines NOTIFY lineLayoutChanged)
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
  Q_PROPERTY(int historyIndex READ historyIndex WRITE setHistoryIndex NOTIFY historyIndexChanged)

public:
  enum class Index : std::int8_t { missing = -1 };

  explicit HistoryRowLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] QVariantMap geometryLayout() const;
  [[nodiscard]] QString query() const { return query_; }
  void setQuery(const QString &query);
  [[nodiscard]] Rect physicalFrame() const noexcept;
  [[nodiscard]] int historyIndex() const noexcept { return history_index_; }
  void setHistoryIndex(int index);

signals:
  void historyIndexChanged();
  void measurementsChanged();
  void layoutChanged();
  void geometryLayoutChanged();
  void lineLayoutChanged();
  void queryChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  struct GeometryState {
    HistoryRowGeometry row;
    qreal density = 1;
    qreal ratio = 1;
    float card_height = 0;
    Rect meta;
    std::uint16_t more = 0;

    bool operator==(const GeometryState &) const = default;
  };

  [[nodiscard]] GeometryState geometryState() const noexcept;
  [[nodiscard]] QRectF logical(Rect area) const noexcept;
  [[nodiscard]] QVariantList commandLines() const;
  [[nodiscard]] QVariantMap commandLine(std::string_view text, Rect bounds, bool continues, HistoryMatchHighlight &highlight) const;
  void prepareCommand();
  void publishLines();

  QVariantMap measurements_;
  QString command_text_;
  QString query_;
  QByteArray query_bytes_;
  QByteArray command_bytes_;
  HistoryRowGeometry geometry_;
  HistoryCard card_;
  qreal density_ = 1;
  qreal ratio_ = 1;
  float command_width_ = 0;
  float cell_width_ = 1;
  float cell_height_ = 1;
  std::uint32_t first_line_columns_ = 0;
  int history_index_ = static_cast<int>(Index::missing);
  bool measurements_dirty_ = true;
  bool query_dirty_ = false;
  bool expanded_ = false;
};

}
