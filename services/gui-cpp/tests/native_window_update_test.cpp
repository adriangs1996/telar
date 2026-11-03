#include "assertions.hpp"
#include "gui_wait.hpp"
#include "platform/awake_clock.hpp"
#include "platform/window.hpp"
#include "presentation/frame_pacer.hpp"
#include "qt/window_frame_pacer.hpp"
#include <QEvent>
#include <QGuiApplication>
#include <QWindow>
#include <exception>
#include <iostream>
#include <qpa/qplatformwindow.h>
#include <utility>

namespace {

using telar::gui::test::require;
using telar::gui::test::waitForGuiCondition;

constexpr int wait_ms = 2000;
constexpr int duplicate_observation_ms = 50;

class UpdateWindow final : public QWindow {
public:
  int received = 0;
  bool request_again = false;

  bool event(QEvent *event) override {
    if (event->type() == QEvent::UpdateRequest) {
      ++received;
      if (std::exchange(request_again, false)) {
        requestUpdate();
      }

      return true;
    }

    return QWindow::event(event);
  }
};

}

int main(int argc, char **argv) try {
  const QGuiApplication application{argc, argv};
  require(telar::gui::platform::supportsImmediateWindowUpdates(), "native update test requires Cocoa");
  UpdateWindow window;
  window.show();
  require(waitForGuiCondition([&] {
            return window.isExposed();
          },
                              wait_ms),
          "window must be exposed");
  telar::gui::qt::WindowFramePacer<telar::gui::platform::AwakeClock, QWindow> pacing{window};
  telar::gui::FramePacer::Pane pane{.pane_id = 1, .frame_id = 1, .attached = true, .attachment_generation = 1};

  const auto before = window.received;
  window.requestUpdate();
  require(window.handle()->hasPendingUpdateRequest(), "Qt must own the pending update");
  pacing.noteInput(pane, telar::gui::platform::AwakeClock::nowNanoseconds());
  ++pane.frame_id;
  pacing.requestInputFrame(pane);
  pacing.requestInputFrame(pane);
  require(waitForGuiCondition([&] {
            return window.received > before;
          },
                              wait_ms),
          "content must deliver its pending update");
  require(window.received == before + 1, "content requests must coalesce");
  require(!pacing.pending() && !window.handle()->hasPendingUpdateRequest(), "both schedulers must consume the delivered request");
  require(!waitForGuiCondition([&] {
    return window.received > before + 1;
  },
                               duplicate_observation_ms),
          "display link must not deliver a duplicate");

  window.requestUpdate();
  pacing.noteInput(pane, telar::gui::platform::AwakeClock::nowNanoseconds());
  ++pane.frame_id;
  pacing.requestInputFrame(pane);
  telar::gui::platform::deliverPendingWindowUpdate(window);
  require(window.received == before + 2, "platform delivery must remain available");
  require(waitForGuiCondition([&] {
            return !pacing.pending();
          },
                              wait_ms),
          "early timer must release an already delivered request");
  require(window.received == before + 2, "early timer must not repeat a consumed update");

  window.request_again = true;
  window.requestUpdate();
  telar::gui::platform::deliverPendingWindowUpdate(window);
  require(window.received == before + 3 && window.handle()->hasPendingUpdateRequest(), "updates requested during delivery must survive");
  require(waitForGuiCondition([&] {
            return window.received == before + 4;
          },
                              wait_ms),
          "display link must deliver newly requested content");
  require(!window.handle()->hasPendingUpdateRequest(), "new content must consume its own update");
  std::cout << "Native window update coalescence passed\n";

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
