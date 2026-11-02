#pragma once

#include <cstdint>

namespace telar::gui::platform {

struct AwakeClock {
  [[nodiscard]] static std::uint64_t nowNanoseconds() noexcept;
};

}
