#pragma once

#include <cstdint>

namespace telar::gui::platform {

void signalProcessGroup(std::int64_t process, bool force) noexcept;

}
