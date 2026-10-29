#include "core/configuration.hpp"
#include "gui_wait.hpp"
#include "presentation/frame_pacer.hpp"
#include "qt/window_frame_pacer.hpp"
#include <QCoreApplication>
#include <QEvent>
#include <QObject>
#include <QWindow>
#include <QtCore/qtmetamacros.h>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>

namespace {

using telar::gui::FramePacer;
using telar::gui::qt::WindowFramePacer;
using telar::gui::test::waitForGuiCondition;

constexpr int wait_ms = 2000;
constexpr std::uint64_t started_ns = FramePacer::nanoseconds_per_second;
constexpr std::uint64_t next_input_ns = started_ns + 1;

struct ControlledClock {
  static inline std::uint64_t now_ns = started_ns;

  static std::uint64_t nowNanoseconds() noexcept {
    return now_ns;
  }
};

class ControlledWindow final : public QObject {
public:
  [[nodiscard]] bool isVisible() const noexcept {
    return visible_;
  }

  [[nodiscard]] bool isExposed() const noexcept {
    return visible_;
  }

  [[nodiscard]] QWindow::Visibility visibility() const noexcept {
    return visible_ ? QWindow::Windowed : QWindow::Hidden;
  }

  [[nodiscard]] int received() const noexcept {
    return received_;
  }

  void hide() noexcept {
    visible_ = false;
  }

  void request() {
    QEvent event{QEvent::UpdateRequest};
    QCoreApplication::sendEvent(this, &event);
  }

  bool event(QEvent *event) override {
    if (event->type() == QEvent::UpdateRequest) {
      ++received_;

      return true;
    }

    return QObject::event(event);
  }

private:
  bool visible_ = true;
  int received_ = 0;
};

using TestFramePacer = WindowFramePacer<ControlledClock, ControlledWindow>;

class FrameFixture final : public QObject {
public:
  FrameFixture() {
    pacing_.emplace(window_);
    pacing_->configure(FramePacer::default_interval_ns, telar::gui::Configuration::minimum_fps);
    pacing_->record(panes_, ControlledClock::now_ns);
    window_.installEventFilter(this);
  }

  void request() {
    window_.request();
  }

  void hide() {
    window_.hide();
  }

  TestFramePacer &framePacer() {
    if (!pacing_) {
      throw std::logic_error{"The frame pacer has already been released"};
    }

    return *pacing_;
  }

  FramePacer::Pane &pane() noexcept {
    return panes_.front();
  }

  [[nodiscard]] std::span<const FramePacer::Pane> panes() const noexcept {
    return panes_;
  }

  [[nodiscard]] int admitted() const noexcept {
    return window_.received();
  }

  void releasePacer() {
    pacing_.reset();
  }

  bool eventFilter(QObject *watched, QEvent *event) override {
    if (event->type() != QEvent::UpdateRequest) {
      return QObject::eventFilter(watched, event);
    }

    if (pacing_) {
      if (pacing_->defer(panes_)) {
        return true;
      }

      pacing_->record(panes_, ControlledClock::now_ns);
    }

    return false;
  }

private:
  ControlledWindow window_;
  std::optional<TestFramePacer> pacing_;
  std::array<FramePacer::Pane, 1> panes_{FramePacer::Pane{.pane_id = 1, .frame_id = 1, .attached = true, .attachment_generation = 1}};
};

class WindowFramePacerTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void init() {
    ControlledClock::now_ns = started_ns;
  }

  Q_SLOT static void pendingFrameArrivesWithoutAnotherUpdate() {
    FrameFixture window;
    window.request();
    QVERIFY(window.framePacer().pending());
    QCOMPARE(window.admitted(), 0);

    ControlledClock::now_ns += FramePacer::maximum_interval_ns;
    QVERIFY(waitForGuiCondition([&] {
      return window.admitted() == 1;
    },
                                wait_ms));
    QVERIFY(!window.framePacer().pending());
  }

  Q_SLOT static void visiblePaneOutputUsesItsInputGrace() {
    FrameFixture window;
    window.request();
    ControlledClock::now_ns = next_input_ns;
    window.framePacer().noteInput(window.pane(), ControlledClock::now_ns);
    ++window.pane().frame_id;
    window.framePacer().reconsider(window.panes());

    QVERIFY(waitForGuiCondition([&] {
      return window.admitted() == 1;
    },
                                wait_ms));
    QCOMPARE(ControlledClock::now_ns, next_input_ns);
    QVERIFY(!window.framePacer().pending());
  }

  Q_SLOT static void anotherPaneCannotReleaseThePendingFrame() {
    FrameFixture window;
    window.request();
    ControlledClock::now_ns = next_input_ns;
    auto other = window.pane();
    ++other.pane_id;
    window.framePacer().noteInput(other, ControlledClock::now_ns);
    ++window.pane().frame_id;
    window.framePacer().reconsider(window.panes());

    constexpr int observation_ms = 50;
    QVERIFY(!waitForGuiCondition([&] {
      return window.admitted() != 0;
    },
                                 observation_ms));
    QVERIFY(window.framePacer().pending());
    ControlledClock::now_ns += FramePacer::maximum_interval_ns;
    QVERIFY(waitForGuiCondition([&] {
      return window.admitted() == 1;
    },
                                wait_ms));
  }

  Q_SLOT static void fasterCadenceReconsidersTheExistingRequest() {
    FrameFixture window;
    window.request();
    ControlledClock::now_ns += FramePacer::minimum_interval_ns;
    window.framePacer().configure(FramePacer::minimum_interval_ns, telar::gui::Configuration::maximum_fps);

    QVERIFY(waitForGuiCondition([&] {
      return window.admitted() == 1;
    },
                                wait_ms));
    QVERIFY(!window.framePacer().pending());
  }

  Q_SLOT static void hidingCancelsTheDeferredRequest() {
    FrameFixture window;
    window.request();
    window.hide();
    window.request();
    QVERIFY(!window.framePacer().pending());
    const auto admitted = window.admitted();
    ControlledClock::now_ns += FramePacer::maximum_interval_ns;
    constexpr int observation_ms = 50;
    QVERIFY(!waitForGuiCondition([&] {
      return window.admitted() != admitted;
    },
                                 observation_ms));
  }

  Q_SLOT static void destroyingTheAdapterReturnsTheHeldRequest() {
    FrameFixture window;
    window.request();
    QVERIFY(window.framePacer().pending());
    window.releasePacer();

    QVERIFY(waitForGuiCondition([&] {
      return window.admitted() == 1;
    },
                                wait_ms));
  }

  Q_SLOT static void destroyingTheWindowCancelsThePendingTimer() {
    auto window = std::make_unique<ControlledWindow>();
    TestFramePacer pacing{*window};
    const std::array panes{FramePacer::Pane{.pane_id = 1, .frame_id = 1, .attached = true, .attachment_generation = 1}};
    pacing.record(panes, ControlledClock::now_ns);
    QVERIFY(pacing.defer(panes));
    window.reset();
    QVERIFY(!pacing.pending());
  }
};

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  WindowFramePacerTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "window_frame_pacer_test.moc"
