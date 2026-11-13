#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <array>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <algorithm>
#include <cmath>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#pragma once


import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::qt {

class HistoryEmptyLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
  Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
  Q_PROPERTY(QString title READ title NOTIFY labelsChanged)
  Q_PROPERTY(QString subtitle READ subtitle NOTIFY labelsChanged)
  Q_PROPERTY(QString action READ action NOTIFY labelsChanged)
  Q_PROPERTY(bool emphasized READ emphasized NOTIFY labelsChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

public:
  explicit HistoryEmptyLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap input() const;
  void setInput(const QVariantMap &input);
  [[nodiscard]] QVariantMap measurements() const;
  void setMeasurements(const QVariantMap &measurements);
  [[nodiscard]] QString title() const;
  [[nodiscard]] QString subtitle() const;
  [[nodiscard]] QString action() const;
  [[nodiscard]] bool emphasized() const noexcept;
  [[nodiscard]] QVariantMap layout() const;

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

  QVariantMap input_;
  QVariantMap measurements_;
  HistoryEmpty content_;
  HistoryEmptyGeometry geometry_;
  qreal density_ = 1;
  qreal ratio_ = 1;
};

}
