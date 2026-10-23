// Checks that the workbench's keyboard router gives a pane the keyboard with another application
// in front before the desktop ever had the keyboard, with this process in front, and with another
// application in front again, as when the focus moves from another application's window to a
// pane. It reports AppKit's view and whether the router holds the
// pane, and exits nonzero when it does not.

#include "support/external_window_probe.hpp"
#include "support/keyboard_focus_probe.hpp"
#include "ui/workbench/keyboard_router.hpp"
#include <QGuiApplication>
#include <QQuickWindow>
#include <chrono>
#include <cstdio>
#include <memory>

namespace {
  using Clock = std::chrono::steady_clock;

  void pump(std::chrono::milliseconds duration) {
    const auto until = Clock::now() + duration;
    while (Clock::now() < until) {
      QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    }
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  keyboard_focus_probe::becomeAccessory();
  workbench::KeyboardRouter router;
  QQuickWindow pane;
  pane.setGeometry(200, 200, 400, 300);
  router.adopt(pane, {});
  pane.show();
  pump(std::chrono::milliseconds{500});

  const auto finder = external_window_probe::processNamed("com.apple.finder");
  int failures = 0;
  // Finder first: the input window has never been key, as when the desktop starts on a tab
  // holding only another application's window.
  for (const bool other_in_front : {true, false, true}) {
    if (other_in_front) {
      external_window_probe::activate(finder, false);
    }

    pump(std::chrono::milliseconds{600});
    std::printf("%s\n", other_in_front ? "with Finder in front" : "with this process in front");
    std::printf("  before route: %s holds=%d\n",
                keyboard_focus_probe::describe(*QGuiApplication::allWindows().first()).c_str(),
                router.holds(pane));
    router.route(pane);
    pump(std::chrono::milliseconds{600});
    QWindow *input = nullptr;
    for (auto *window : QGuiApplication::allWindows()) {
      if (window->title() == "Telar Keyboard") {
        input = window;
      }
    }

    std::printf("  after route:  %s holds=%d focus window=%s\n",
                input ? keyboard_focus_probe::describe(*input).c_str() : "no input window",
                router.holds(pane),
                QGuiApplication::focusWindow() == &pane ? "the pane" : "another window");
    failures += !router.holds(pane);
  }

  // A pane that held the keyboard closes, then another application comes to the front: Qt drops
  // a destroyed focus window without announcing it, so it never reports losing the keyboard.
  {
    auto closing = std::make_unique<QQuickWindow>();
    closing->setGeometry(220, 220, 300, 200);
    router.adopt(*closing, {});
    closing->show();
    router.route(*closing);
    pump(std::chrono::milliseconds{400});
    closing.reset();
    pump(std::chrono::milliseconds{200});
    external_window_probe::activate(finder, false);
    pump(std::chrono::milliseconds{600});
    router.route(pane);
    pump(std::chrono::milliseconds{600});
    std::printf("after the focused pane closed and Finder came in front\n");
    std::printf("  holds=%d app active=%s\n",
                router.holds(pane),
                keyboard_focus_probe::active() ? "yes" : "no");
    failures += !router.holds(pane);
  }

  return failures == 0 ? 0 : 1;
}
