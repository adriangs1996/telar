#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "input/wheel_accumulator.hpp"
#include "history/choice.hpp"
#include "input/history_hover.hpp"
#include "presentation/history_inspection.hpp"
#include "presentation/history_inspection_geometry.hpp"
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QWheelEvent>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace telar::gui::qt {

class HistoryInspectionLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
  Q_PROPERTY(QVariantList advances READ advances WRITE setAdvances NOTIFY advancesChanged)
  Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)
  Q_PROPERTY(int scroll READ scroll WRITE setScroll NOTIFY scrollChanged)

public:
  explicit HistoryInspectionLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] QVariantMap input() const;
  void setInput(const QVariantMap &input);
  [[nodiscard]] QVariantList advances() const;
  void setAdvances(const QVariantList &advances);
  [[nodiscard]] QVariantMap layout() const;
  [[nodiscard]] int scroll() const;
  void setScroll(int scroll);
  [[nodiscard]] std::size_t hoverTargets(std::uint64_t generation, std::span<HistoryHoverTarget> destination) const;

signals:
  void inputChanged();
  void advancesChanged();
  void layoutChanged();
  void scrollChanged();

protected:
  void updatePolish() override;
  void componentComplete() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void wheelEvent(QWheelEvent *event) override;

private:
  [[nodiscard]] QRectF logical(Rect area) const noexcept;
  [[nodiscard]] float physical(const QVariant &value) const;
  [[nodiscard]] ChromeMetrics metrics(qreal ratio) const;
  [[nodiscard]] QVariantMap projectLine(const HistoryInspectionLine &line, const HistoryInspectionGeometry &geometry, std::uint16_t index) const;
  [[nodiscard]] QVariantMap prepareContent(const HistoryInspectionGeometry &geometry);
  [[nodiscard]] QVariantList prepareButtons(const HistoryInspectionGeometry &geometry, ChromeMetrics chrome);

  QVariantMap input_;
  QVariantList advances_;
  QVariantMap layout_;
  std::array<Rect, HistoryInspectionGeometry::maximum_actions> button_bounds_{};
  HistoryChoice choice_;
  bool pane_open_ = false;
  bool ready_ = false;
  qreal density_ = 1;
  int scroll_ = 0;
  WheelAccumulator wheel_;
};

}
