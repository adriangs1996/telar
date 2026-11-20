#include "foundation/core/application_memory.hpp"
#include "ui/kit/input/native_pointer_events.hpp"
#include <QCoreApplication>
#include <QEvent>
#include <QGuiApplication>
#include <QObject>
#include <QPointF>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtGui/qpa/qwindowsysteminterface.h>
#include <QtGui/qpa/qwindowsysteminterface_p.h>
#include <array>
#include <cstddef>
#include <exception>
#include <iostream>
#include <optional>
#include <span>
#include <utility>

import telar.testing;
import telar.base.ds;

namespace {

  using telar::gui::ApplicationAllocator;
  using telar::gui::ApplicationMemory;
  using telar::gui::qt::NativePointerEvents;
  using telar::testing::check;

  struct Observation {
    QEvent::Type type = QEvent::None;
    bool moving = false;
  };

  class Recorder final : public QObject {
  public:
    explicit Recorder(const NativePointerEvents& events)
        : events_(events) {}

    ~Recorder() override = default;
    Recorder(const Recorder&) = delete;
    Recorder& operator=(const Recorder&) = delete;
    Recorder(Recorder&&) = delete;
    Recorder& operator=(Recorder&&) = delete;

    bool eventFilter([[maybe_unused]] QObject* watched, QEvent* event) override {
      if (event->type() == QEvent::MouseMove || event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
        check(count_ < observations_.size(), "native delivery must retain its bounded event trace");
        observations_.atMut(count_++) = {.type = event->type(), .moving = events_.moving()};
      }

      return false;
    }

    [[nodiscard]] std::span<const Observation> observations() const noexcept {
      return {observations_.data(), count_};
    }

  private:
    static constexpr std::size_t trace_capacity = 8;
    telar::ds::Array<Observation, trace_capacity> observations_{};
    std::size_t count_ = 0;
    const NativePointerEvents& events_;
  };

  void deliver(QWindow& window, QEvent::Type kind, QPointF position, Qt::MouseButtons buttons, Qt::MouseButton button) {
    static_cast<void>(QWindowSystemInterface::handleMouseEvent<QWindowSystemInterface::SynchronousDelivery>(&window, position, window.mapToGlobal(position), buttons, button, kind));
  }

  void rawMotionExcludesQtButtonSplitting(ApplicationAllocator& memory) {
    NativePointerEvents events{memory};
    QWindow window;

    window.show();
    QCoreApplication::processEvents();
    Recorder recorder{events};

    window.installEventFilter(&recorder);
    constexpr QPointF first{20, 20};
    constexpr QPointF clicked{40, 40};
    constexpr QPointF last{60, 60};

    deliver(window, QEvent::MouseMove, first, Qt::NoButton, Qt::NoButton);
    deliver(window, QEvent::MouseButtonPress, clicked, Qt::LeftButton, Qt::LeftButton);
    deliver(window, QEvent::MouseButtonRelease, clicked, Qt::NoButton, Qt::LeftButton);
    deliver(window, QEvent::MouseMove, last, Qt::NoButton, Qt::NoButton);
    constexpr std::size_t expected_deliveries = 5;

    check(recorder.observations().size() == expected_deliveries, "the observer must preserve both native events and Qt's extra move before a changed-position press");
    check(recorder.observations()[0].moving && recorder.observations()[4].moving, "actual native motion must be observable during delivery");
    check(recorder.observations()[1].type == QEvent::MouseMove && !recorder.observations()[1].moving, "Qt's button-position synchronization must not become an observed hover motion");
    check(recorder.observations()[2].type == QEvent::MouseButtonPress && !recorder.observations()[2].moving, "the original press must still reach its recipient unchanged");
    check(recorder.observations()[3].type == QEvent::MouseButtonRelease && !recorder.observations()[3].moving, "the original release must still reach its recipient unchanged");
    check(!events.moving(), "native-event scope must retire immediately after synchronous dispatch");
  }

  void observersMayRetireOutOfOrder(ApplicationAllocator& memory) {
    const auto* const original = QWindowSystemInterfacePrivate::eventHandler;
    telar::ds::Option<NativePointerEvents> first{std::in_place, memory};
    telar::ds::Option<NativePointerEvents> second{std::in_place, memory};
    telar::ds::Option<NativePointerEvents> third{std::in_place, memory};
    const auto* const head = QWindowSystemInterfacePrivate::eventHandler;

    second.reset();
    first.reset();
    check(QWindowSystemInterfacePrivate::eventHandler == head, "retiring earlier windows must preserve the live observer chain head");
    QWindow window;

    window.show();
    QCoreApplication::processEvents();
    Recorder recorder{*third};

    window.installEventFilter(&recorder);
    constexpr QPointF point{80, 80};

    deliver(window, QEvent::MouseMove, point, Qt::NoButton, Qt::NoButton);
    check(recorder.observations().size() == 1 && recorder.observations()[0].moving, "a live observer must dispatch safely after its predecessors have retired");
    window.removeEventFilter(&recorder);
    third.reset();
    check(QWindowSystemInterfacePrivate::eventHandler == original, "the final observer must restore the previous Qt handler");
  }

  class RetiringObserver final : public QObject {
  public:
    explicit RetiringObserver(telar::ds::Option<NativePointerEvents>& events)
        : events_(events) {}

    ~RetiringObserver() override = default;
    RetiringObserver(const RetiringObserver&) = delete;
    RetiringObserver& operator=(const RetiringObserver&) = delete;
    RetiringObserver(RetiringObserver&&) = delete;
    RetiringObserver& operator=(RetiringObserver&&) = delete;

    bool eventFilter([[maybe_unused]] QObject* watched, QEvent* event) override {
      if (event->type() == QEvent::MouseMove) {
        check(events_.hasValue() && events_->moving(), "the retiring observer must see its active native motion");
        events_.reset();
      }

      return false;
    }

  private:
    telar::ds::Option<NativePointerEvents>& events_;
  };

  void observerMayRetireDuringDelivery(ApplicationAllocator& memory) {
    const auto* const original = QWindowSystemInterfacePrivate::eventHandler;
    telar::ds::Option<NativePointerEvents> events{std::in_place, memory};
    QWindow window;

    window.show();
    QCoreApplication::processEvents();
    RetiringObserver retiring{events};

    window.installEventFilter(&retiring);
    constexpr QPointF point{100, 100};

    deliver(window, QEvent::MouseMove, point, Qt::NoButton, Qt::NoButton);
    check(!events.hasValue(), "native dispatch must survive the recipient destroying its observer");
    check(QWindowSystemInterfacePrivate::eventHandler == original, "synchronous retirement must restore Qt's previous handler");
  }

  // Runs `test` with an application memory of its own.
  template <void (*test)(ApplicationAllocator&)>
  void withMemory() {
    ApplicationMemory application_memory;

    test(application_memory.memory());
  }

  const telar::testing::Case case_raw_motion{"native_pointer_events.raw_motion_excludes_qt_button_splitting", withMemory<rawMotionExcludesQtButtonSplitting>};
  const telar::testing::Case case_out_of_order{"native_pointer_events.observers_may_retire_out_of_order", withMemory<observersMayRetireOutOfOrder>};
  const telar::testing::Case case_during_delivery{"native_pointer_events.observer_may_retire_during_delivery", withMemory<observerMayRetireDuringDelivery>};

}
