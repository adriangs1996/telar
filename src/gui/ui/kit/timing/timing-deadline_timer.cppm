export module telar.gui.ui.kit.timing:deadline_timer;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline void scheduleDeadline(QTimer& timer, ds::Option<std::uint64_t> deadline_ns, std::uint64_t now_ns) {
    timer.stop();
    if (!deadline_ns) {
      return;
    }

    const auto remaining = *deadline_ns - std::min(*deadline_ns, now_ns);
    constexpr auto unit = application::notifications::NotificationInput::nanoseconds_per_millisecond;
    const auto delay = (remaining / unit) + static_cast<std::uint64_t>(remaining % unit != 0);

    timer.start(static_cast<int>(std::clamp<std::uint64_t>(delay, 1, std::numeric_limits<int>::max())));
  }

}
