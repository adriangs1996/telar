module;

#include <cstdint>
#include "process_group.h"

module telar.gui.platform.private_file_stamp;



namespace telar::gui::platform {

void signalProcessGroup(std::int64_t process, bool force) noexcept {
  telarSignalProcessGroup(process, static_cast<int>(force));
}

}
