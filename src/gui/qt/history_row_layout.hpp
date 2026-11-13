#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <bit>
#include <stdexcept>
#include <ghostty/vt/unicode.h>
#include <limits>
#include <concepts>
#include <QByteArray>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>

#pragma once


import telar.gui.core.metrics;
import telar.gui.presentation.history_meta_geometry;
import telar.gui.presentation.form_field_geometry;

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
