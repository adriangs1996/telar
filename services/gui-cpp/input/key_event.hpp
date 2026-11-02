#pragma once

#include "binding.hpp"
#include <cstdint>

namespace telar::gui {

enum class KeyPhase : std::uint8_t {
  press,
  repeat,
  release,
};

struct BindingEvent {
  KeyChord chord;
  KeyPhase phase = KeyPhase::press;
  std::uint64_t physical = 0;
};

struct BindingRepeat {
  std::uint64_t interval_ns = 0;
  std::uint64_t owner = 0;

  bool operator==(const BindingRepeat &) const = default;
};

}
