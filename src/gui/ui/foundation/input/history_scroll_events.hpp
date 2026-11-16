#pragma once

#include "platform/scroll_event.hpp"
#include <QAbstractNativeEventFilter>
#include <QByteArray>
#include <QCoreApplication>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <type_traits>

namespace telar::gui::qt {

  // Hands the application's native scroll events to `Receiver::handleNativeScroll` while active.
  template <typename Receiver>
  class HistoryScrollEvents final : public QAbstractNativeEventFilter {
  public:
    explicit HistoryScrollEvents(Receiver& receiver)
        : receiver_(receiver) {}

    ~HistoryScrollEvents() override {
      if (installed_ && QCoreApplication::instance() != nullptr) {
        QCoreApplication::instance()->removeNativeEventFilter(this);
      }
    }

    HistoryScrollEvents(const HistoryScrollEvents&) = delete;
    HistoryScrollEvents& operator=(const HistoryScrollEvents&) = delete;
    HistoryScrollEvents(HistoryScrollEvents&&) = delete;
    HistoryScrollEvents& operator=(HistoryScrollEvents&&) = delete;

    void setActive(bool active) {
      if (active == installed_) {
        return;
      }

      installed_ = active;
      if (active) {
        QCoreApplication::instance()->installNativeEventFilter(this);
      } else {
        QCoreApplication::instance()->removeNativeEventFilter(this);
      }
    }

    bool nativeEventFilter(const QByteArray& event_type, void* message, [[maybe_unused]] qintptr* result) override {
      return receiver_.handleNativeScroll({event_type.constData(), static_cast<std::size_t>(event_type.size())}, message);
    }

  private:
    Receiver& receiver_;
    bool installed_ = false;
  };

  template <typename Receiver>
  class InactiveHistoryScrollEvents {
  public:
    explicit InactiveHistoryScrollEvents([[maybe_unused]] Receiver& receiver) noexcept {}

    void setActive([[maybe_unused]] bool active) noexcept {}
  };

  template <typename Receiver>
  using ActiveHistoryScrollEvents = std::conditional_t<platform::native_scroll_events, HistoryScrollEvents<Receiver>, InactiveHistoryScrollEvents<Receiver>>;

}
