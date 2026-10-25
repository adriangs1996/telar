#pragma once

#include <cstdint>
#include <string_view>

namespace telar::runtime {

enum class LaunchPhase : std::uint8_t {
  pane_registration,
  wait_actor,
  output_actor
};

struct LaunchFailure {
  std::uint64_t generation = 0;
  LaunchPhase phase = LaunchPhase::pane_registration;
  std::string_view cause;
};

}
