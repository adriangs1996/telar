module;
#include "platform/window_activation.hpp"

export module telar.gui.tests.frame_fixture;

import std;
import telar.gui.qt;
import telar.gui.qt.testing;
import telar.gui.tests.gui_wait;

export namespace telar::gui::test {

  enum class TestWindowKind : std::uint8_t {
    application,
    component,
  };

  inline bool waitForSynchronizedFrame(QQuickWindow& window, int timeout_ms) {
    const QPointer<QQuickWindow> lifetime{&window};
    bool synchronized = false;
    bool delivered = false;
    const QObject observer;

    QObject::connect(&window, &QQuickWindow::afterSynchronizing, &observer, [&] {
      synchronized = true;
    },
        Qt::QueuedConnection);
    QObject::connect(&window, &QQuickWindow::frameSwapped, &observer, [&] {
      delivered = synchronized;
    },
        Qt::QueuedConnection);
    window.update();

    const auto completed = waitForGuiCondition([&] {
      return lifetime.isNull() || delivered;
    },
        timeout_ms);

    if (lifetime.isNull()) {
      return false;
    }

    if (!completed) {
      telar::qt::info() << "Frame delivery timed out" << "synchronized" << synchronized << window.geometry() << "exposed" << window.isExposed();

      return false;
    }

    return true;
  }

  inline bool showWindow(QQuickWindow& window, int timeout_ms, TestWindowKind kind = TestWindowKind::application) {
    activateApplication();
    window.setScreen(QGuiApplication::primaryScreen());
    if (const auto* screen = window.screen()) {
      window.setPosition(screen->availableGeometry().topLeft());
    }

    if (kind == TestWindowKind::component) {
      configureComponentWindow(window);
    }

    window.show();

    return QTest::qWaitForWindowExposed(&window, timeout_ms) && waitForSynchronizedFrame(window, timeout_ms);
  }

  inline bool showComponentWindow(QQuickWindow& window, int timeout_ms) {
    const auto requested_size = window.size();

    if (!showWindow(window, timeout_ms, TestWindowKind::component)) {
      return false;
    }

    if (window.size() == requested_size) {
      return true;
    }

    window.resize(requested_size);

    if (!waitForSynchronizedFrame(window, timeout_ms)) {
      return false;
    }

    if (window.size() != requested_size) {
      telar::qt::info() << "Component window size changed" << "requested" << requested_size << "received" << window.size();

      return false;
    }

    return true;
  }

}
