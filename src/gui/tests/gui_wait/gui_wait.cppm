export module telar.gui.tests.gui_wait;

import std;
import telar.gui.qt;

export namespace telar::gui::test {

  template <typename Predicate>
    requires std::predicate<const Predicate&>
  bool waitForGuiCondition(const Predicate& condition, int timeout_ms) {
    if (condition()) {
      return true;
    }

    if (timeout_ms <= 0) {
      return false;
    }

    constexpr std::chrono::milliseconds poll_interval{10};
    QEventLoop events;
    QTimer observation;
    QTimer deadline;

    deadline.setSingleShot(true);
    QObject::connect(&deadline, &QTimer::timeout, &events, &QEventLoop::quit);
    QObject::connect(&observation, &QTimer::timeout, &events, [&] {
      if (condition()) {
        events.quit();
      }
    });

    observation.start(poll_interval);
    deadline.start(timeout_ms);
    events.exec();

    return condition();
  }

}
