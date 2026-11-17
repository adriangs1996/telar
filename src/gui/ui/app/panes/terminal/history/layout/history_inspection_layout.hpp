#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "input/wheel_accumulator.hpp"
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QWheelEvent>
#include <QtCore/qcontainerfwd.h>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>

#pragma once

import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.presentation.history_pointer;
import telar.gui.presentation.history_inspection;
import telar.gui.presentation.history_inspection_geometry;

namespace telar::gui::qt {

  class HistoryInspectionLayout : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
    Q_PROPERTY(QVariantList advances READ advances WRITE setAdvances NOTIFY advancesChanged)
    Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)
    Q_PROPERTY(int scroll READ scroll WRITE setScroll NOTIFY scrollChanged)

  public:
    explicit HistoryInspectionLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantList advances() const;
    void setAdvances(const QVariantList& advances);
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
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void wheelEvent(QWheelEvent* event) override;

  private:
    [[nodiscard]] QRectF logical(Rect area) const noexcept;
    [[nodiscard]] float physical(const QVariant& value) const;
    [[nodiscard]] ChromeMetrics metrics(qreal ratio) const;
    [[nodiscard]] QVariantMap projectLine(const HistoryInspectionLine& line, const HistoryInspectionGeometry& geometry, std::uint16_t index) const;
    [[nodiscard]] QVariantMap prepareContent(const HistoryInspectionGeometry& geometry);
    [[nodiscard]] QVariantList prepareButtons(const HistoryInspectionGeometry& geometry, ChromeMetrics chrome);

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
