module;

#include "platform/process_group.h"
#include <cstdint>

module telar.gui.platform.private_file_stamp;

import std;

namespace telar::gui::platform {

  void signalProcessGroup(std::int64_t process, bool force) noexcept {
    telarSignalProcessGroup(process, static_cast<int>(force));
  }

}
