#pragma once

#include "platform/scroll_event.hpp"
#include <QAbstractNativeEventFilter>
#include <QByteArray>
#include <QCoreApplication>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <string_view>
#include <type_traits>

namespace telar::gui::qt {

  // The filter apart from its receiver's type: whether a class template's unused virtual members are
  // instantiated is up to each compiler, so the virtual ones live in this plain class.
  class NativeScrollFilter : public QAbstractNativeEventFilter {
  public:
    ~NativeScrollFilter() override {
      if (installed_ && QCoreApplication::instance() != nullptr) {
        QCoreApplication::instance()->removeNativeEventFilter(this);
      }
    }

    NativeScrollFilter(const NativeScrollFilter&) = delete;
    NativeScrollFilter& operator=(const NativeScrollFilter&) = delete;
    NativeScrollFilter(NativeScrollFilter&&) = delete;
    NativeScrollFilter& operator=(NativeScrollFilter&&) = delete;

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
      return handler_(receiver_, {event_type.constData(), static_cast<std::size_t>(event_type.size())}, message);
    }

  protected:
    using Handler = bool (*)(void* receiver, std::string_view event_type, const void* message);

    NativeScrollFilter(void* receiver, Handler handler) noexcept
        : receiver_(receiver),
          handler_(handler) {}

  private:
    void* receiver_;
    Handler handler_;
    bool installed_ = false;
  };

  // Hands the application's native scroll events to `Receiver::handleNativeScroll` while active.
  template <typename Receiver>
  class HistoryScrollEvents final : public NativeScrollFilter {
  public:
    explicit HistoryScrollEvents(Receiver& receiver)
        : NativeScrollFilter{&receiver, &handle} {}

  private:
    static bool handle(void* receiver, std::string_view event_type, const void* message) {
      return static_cast<Receiver*>(receiver)->handleNativeScroll(event_type, message);
    }
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
