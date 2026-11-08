#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <array>
#include <string_view>
#include <optional>
#include <utility>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <bit>
#include <stdexcept>
#include <ghostty/vt/unicode.h>
#include <limits>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <QQuickItem>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>

#pragma once


import telar.gui.core.metrics;
import telar.gui.input.child_mouse;
import telar.gui.presentation.history_meta_geometry;

namespace telar::gui::qt {

class HistoryMetaLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QVariantList facts READ facts NOTIFY labelsChanged)
  Q_PROPERTY(QVariantList actions READ actions NOTIFY labelsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  explicit HistoryMetaLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap input() const;
  void setInput(const QVariantMap &input);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QVariantList facts() const;
  [[nodiscard]] QVariantList actions() const;
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] HistoryActionSurface actionSurface(std::uint64_t generation) const;

signals:
  void inputChanged();
  void measurementsChanged();
  void labelsChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  void prepareLabels();
  [[nodiscard]] QRectF logical(Rect area) const noexcept;

  QVariantMap input_;
  QVariantMap measurements_;
  QVariantList facts_;
  QVariantList actions_;
  HistoryMetaGeometry geometry_;
  qreal density_ = 1;
  qreal ratio_ = 1;
};

}
