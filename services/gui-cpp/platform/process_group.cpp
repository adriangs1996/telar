#include "process_group.hpp"
#include "process_group.h"
#include <cstdint>

namespace telar::gui::platform {

void signalProcessGroup(std::int64_t process, bool force) noexcept {
  telarSignalProcessGroup(process, static_cast<int>(force));
}

}
