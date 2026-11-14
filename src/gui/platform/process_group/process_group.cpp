module telar.gui.platform.process_group;

import std;
import telar.sys.process;

namespace telar::gui::platform {

  void signalProcessGroup(std::int64_t process, bool force) noexcept {
    if (process <= 1 || process > std::numeric_limits<pid_t>::max()) {
      return;
    }

    (void)::kill(-static_cast<pid_t>(process), force ? SIGKILL : SIGTERM);
  }

}
