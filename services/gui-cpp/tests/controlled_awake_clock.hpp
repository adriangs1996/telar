#pragma once

#include <cstdint>

namespace telar::gui::test {

struct ControlledAwakeClock {
  static void set(std::uint64_t now_ns) noexcept;
};

}
