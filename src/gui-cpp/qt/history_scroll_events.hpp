#pragma once

#include "platform/scroll_event.hpp"
#include <QAbstractNativeEventFilter>
#include <QByteArray>
#include <QtCore/qtypes.h>
#include <type_traits>

namespace telar::gui::qt {

class PointerDispatcher;

class HistoryScrollEvents final : public QAbstractNativeEventFilter {
public:
  explicit HistoryScrollEvents(PointerDispatcher &receiver);
  ~HistoryScrollEvents() override;
  HistoryScrollEvents(const HistoryScrollEvents &) = delete;
  HistoryScrollEvents &operator=(const HistoryScrollEvents &) = delete;
  HistoryScrollEvents(HistoryScrollEvents &&) = delete;
  HistoryScrollEvents &operator=(HistoryScrollEvents &&) = delete;
  void setActive(bool active);
  bool nativeEventFilter(const QByteArray &event_type, void *message, qintptr *result) override;

private:
  PointerDispatcher &receiver_;
  bool installed_ = false;
};

class InactiveHistoryScrollEvents {
public:
  explicit InactiveHistoryScrollEvents([[maybe_unused]] PointerDispatcher &receiver) noexcept {}

  void setActive([[maybe_unused]] bool active) noexcept {}
};

using ActiveHistoryScrollEvents = std::conditional_t<platform::native_scroll_events, HistoryScrollEvents, InactiveHistoryScrollEvents>;

}
