#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace telar {

  // A limit's names view literals where the program declares it, or the frame or row it was read from.
  struct LimitReach {
    std::string_view name{};
    std::string_view noun{};
    std::uint64_t value = 0;
    std::optional<std::uint64_t> requested{};
    std::string_view route{};
  };

}
