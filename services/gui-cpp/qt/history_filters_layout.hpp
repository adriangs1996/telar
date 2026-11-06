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
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <QQuickItem>
#include <QRectF>
#include <QStringList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>

#pragma once


import telar.gui.core.metrics;
import telar.gui.input.child_mouse;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::qt {

class HistoryFiltersLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QVariantList scopeChoices READ scopeChoices NOTIFY labelsChanged)
  Q_PROPERTY(QVariantList authorChoices READ authorChoices NOTIFY labelsChanged)
  Q_PROPERTY(QStringList keyLabels READ keyLabels NOTIFY labelsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  static constexpr std::size_t target_count = history_filter_target_count;

  explicit HistoryFiltersLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap input() const;
  void setInput(const QVariantMap &input);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QVariantList scopeChoices() const;
  [[nodiscard]] QVariantList authorChoices() const;
  [[nodiscard]] QStringList keyLabels() const;
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] std::size_t hoverTargets(std::uint64_t generation, std::span<HistoryHoverTarget> destination) const;

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
  [[nodiscard]] QVariantMap chipRecord(const HistoryFilterChipGeometry &chip) const;

  QVariantMap input_;
  QVariantMap measurements_;
  QVariantList scope_choices_;
  QVariantList author_choices_;
  QStringList key_labels_;
  HistoryFilterGeometry geometry_;
  qreal density_ = 1;
  qreal ratio_ = 1;
};

}
