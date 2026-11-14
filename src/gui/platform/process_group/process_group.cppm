export module telar.gui.platform.process_group;

import std;

export {
  namespace telar::gui::platform {

    void signalProcessGroup(std::int64_t process, bool force) noexcept;

  }
}
