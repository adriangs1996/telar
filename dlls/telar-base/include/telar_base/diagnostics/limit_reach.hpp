#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace telar {

  struct LimitReach {
    std::string_view name{};
    std::string_view noun{};
    std::uint64_t value = 0;
    std::optional<std::uint64_t> requested{};
    std::string_view route{};
  };

}
