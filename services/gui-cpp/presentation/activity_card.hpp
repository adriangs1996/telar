#pragma once

#include <cstdint>

namespace telar::gui {

enum class ActivityCard : std::uint8_t {
  agent,
  task_full,
  task_compact,
};

}
