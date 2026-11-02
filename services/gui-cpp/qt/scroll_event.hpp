#pragma once

#include "input/wheel_accumulator.hpp"
#include <QInputDevice>
#include <QPointF>
#include <QWheelEvent>
#include <QtCore/qnamespace.h>
#include <cstdint>

namespace telar::gui::qt {

[[nodiscard]] inline ScrollPhase scrollPhase(Qt::ScrollPhase phase) noexcept {
  switch (phase) {
  case Qt::NoScrollPhase:
    return ScrollPhase::none;
  case Qt::ScrollBegin:
    return ScrollPhase::begin;
  case Qt::ScrollEnd:
    return ScrollPhase::end;
  default:
    return ScrollPhase::update;
  }
}

[[nodiscard]] inline ScrollSample scrollSample(const QWheelEvent &event, double cell_height) noexcept {
  constexpr double wheel_unit = 120;
  const auto precise = !event.pixelDelta().isNull() && event.source() == Qt::MouseEventSynthesizedBySystem;

  return {.delta = precise ? -event.pixelDelta().y() : -static_cast<double>(event.angleDelta().y()) / wheel_unit, .cell_height = cell_height, .precise = precise, .phase = scrollPhase(event.phase())};
}

class ScrollEventSequence {
public:
  [[nodiscard]] bool compatibilityEvent(const QWheelEvent &event) noexcept {
    const auto device = event.device() == nullptr ? 0 : event.device()->systemId();
    const auto has_delta = !event.angleDelta().isNull() || !event.pixelDelta().isNull();
    const auto compatibility = !has_delta && event.phase() == Qt::ScrollBegin && previous_had_delta_ && previous_phase_ == Qt::ScrollBegin && event.timestamp() == previous_timestamp_ && event.position() == previous_position_ && device == previous_device_;
    previous_had_delta_ = has_delta;
    previous_phase_ = event.phase();
    previous_timestamp_ = event.timestamp();
    previous_position_ = event.position();
    previous_device_ = device;

    return compatibility;
  }

private:
  QPointF previous_position_;
  std::uint64_t previous_timestamp_ = 0;
  std::int64_t previous_device_ = 0;
  Qt::ScrollPhase previous_phase_ = Qt::NoScrollPhase;
  bool previous_had_delta_ = false;
};

}
