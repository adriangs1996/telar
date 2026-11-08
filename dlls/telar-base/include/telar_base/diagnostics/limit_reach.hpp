#pragma once

#include "tbc/view.hpp"

#include <cstdint>
#include <optional>
#include <string_view>

namespace telar {

  using StaticText = tbc::view<std::string_view, tbc::lt::static_storage>;

  // A limit the program declares, named by literals, so a notice can be kept anywhere.
  struct LimitReach {
    StaticText name{};
    StaticText noun{};
    std::uint64_t value = 0;
    std::optional<std::uint64_t> requested{};
    StaticText route{};
  };

}
