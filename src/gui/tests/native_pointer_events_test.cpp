#include "assertions.hpp"
#include "application/dependencies.hpp"
#include "qt/native_pointer_events.hpp"
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

namespace {

using telar::gui::ApplicationAllocator;
using telar::gui::qt::NativePointerEvents;
using telar::gui::test::require;

struct Observation {
  QEvent::Type type = QEvent::None;
  bool moving = false;
};

class Recorder final : public QObject {
public:
  explicit Recorder(const NativePointerEvents &events) : events_(events) {}
  ~Recorder() override = default;
  Recorder(const Recorder &) = delete;
  Recorder &operator=(const Recorder &) = delete;
  Recorder(Recorder &&) = delete;
  Recorder &operator=(Recorder &&) = delete;

  bool eventFilter([[maybe_unused]] QObject *watched, QEvent *event) override {
    if (event->type() == QEvent::MouseMove || event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
      require(count_ < observations_.size(), "native delivery must retain its bounded event trace");
      observations_[count_++] = {.type = event->type(), .moving = events_.moving()};
    }

    return false;
  }

  [[nodiscard]] std::span<const Observation> observations() const noexcept {
    return {observations_.data(), count_};
  }

private:
  static constexpr std::size_t trace_capacity = 8;
  std::array<Observation, trace_capacity> observations_{};
  std::size_t count_ = 0;
  const NativePointerEvents &events_;
};

void deliver(QWindow &window, QEvent::Type kind, QPointF position, Qt::MouseButtons buttons, Qt::MouseButton button) {
  static_cast<void>(QWindowSystemInterface::handleMouseEvent<QWindowSystemInterface::SynchronousDelivery>(&window, position, window.mapToGlobal(position), buttons, button, kind));
}

void rawMotionExcludesQtButtonSplitting(ApplicationAllocator &memory) {
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
  require(recorder.observations().size() == expected_deliveries, "the observer must preserve both native events and Qt's extra move before a changed-position press");
  require(recorder.observations()[0].moving && recorder.observations()[4].moving, "actual native motion must be observable during delivery");
  require(recorder.observations()[1].type == QEvent::MouseMove && !recorder.observations()[1].moving, "Qt's button-position synchronization must not become an observed hover motion");
  require(recorder.observations()[2].type == QEvent::MouseButtonPress && !recorder.observations()[2].moving, "the original press must still reach its recipient unchanged");
  require(recorder.observations()[3].type == QEvent::MouseButtonRelease && !recorder.observations()[3].moving, "the original release must still reach its recipient unchanged");
  require(!events.moving(), "native-event scope must retire immediately after synchronous dispatch");
}

void observersMayRetireOutOfOrder(ApplicationAllocator &memory) {
  const auto *const original = QWindowSystemInterfacePrivate::eventHandler;
  std::optional<NativePointerEvents> first{std::in_place, memory};
  std::optional<NativePointerEvents> second{std::in_place, memory};
  std::optional<NativePointerEvents> third{std::in_place, memory};
  const auto *const head = QWindowSystemInterfacePrivate::eventHandler;
  second.reset();
  first.reset();
  require(QWindowSystemInterfacePrivate::eventHandler == head, "retiring earlier windows must preserve the live observer chain head");
  QWindow window;
  window.show();
  QCoreApplication::processEvents();
  Recorder recorder{*third};
  window.installEventFilter(&recorder);
  constexpr QPointF point{80, 80};
  deliver(window, QEvent::MouseMove, point, Qt::NoButton, Qt::NoButton);
  require(recorder.observations().size() == 1 && recorder.observations()[0].moving, "a live observer must dispatch safely after its predecessors have retired");
  window.removeEventFilter(&recorder);
  third.reset();
  require(QWindowSystemInterfacePrivate::eventHandler == original, "the final observer must restore the previous Qt handler");
}

class RetiringObserver final : public QObject {
public:
  explicit RetiringObserver(std::optional<NativePointerEvents> &events) : events_(events) {}
  ~RetiringObserver() override = default;
  RetiringObserver(const RetiringObserver &) = delete;
  RetiringObserver &operator=(const RetiringObserver &) = delete;
  RetiringObserver(RetiringObserver &&) = delete;
  RetiringObserver &operator=(RetiringObserver &&) = delete;

  bool eventFilter([[maybe_unused]] QObject *watched, QEvent *event) override {
    if (event->type() == QEvent::MouseMove) {
      require(events_.has_value() && events_->moving(), "the retiring observer must see its active native motion");
      events_.reset();
    }

    return false;
  }

private:
  std::optional<NativePointerEvents> &events_;
};

void observerMayRetireDuringDelivery(ApplicationAllocator &memory) {
  const auto *const original = QWindowSystemInterfacePrivate::eventHandler;
  std::optional<NativePointerEvents> events{std::in_place, memory};
  QWindow window;
  window.show();
  QCoreApplication::processEvents();
  RetiringObserver retiring{events};
  window.installEventFilter(&retiring);
  constexpr QPointF point{100, 100};
  deliver(window, QEvent::MouseMove, point, Qt::NoButton, Qt::NoButton);
  require(!events.has_value(), "native dispatch must survive the recipient destroying its observer");
  require(QWindowSystemInterfacePrivate::eventHandler == original, "synchronous retirement must restore Qt's previous handler");
}

}

int main(int argc, char **argv) try {
  const QGuiApplication application{argc, argv};
  ApplicationAllocator memory;
  rawMotionExcludesQtButtonSplitting(memory);
  observersMayRetireOutOfOrder(memory);
  observerMayRetireDuringDelivery(memory);

  return 0;
} catch (const std::exception &failure) {
  std::cerr << failure.what() << '\n';

  return 1;
}
