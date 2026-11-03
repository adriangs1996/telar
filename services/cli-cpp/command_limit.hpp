#pragma once

#include "command_io.hpp"
#include "telar_client/serializers/telar_messages.hpp"

#include <format>

namespace telar::runtime::cli {

inline std::string limitDescription(const LimitReach &reach, std::uint64_t hits = 1) {
  std::string output = std::string{reach.name} + ": ";
  const auto noun = reach.noun.empty() ? "" : " " + std::string{reach.noun};
  if (reach.requested) {
    output += std::format("{}{}; limit {}", *reach.requested, noun, reach.value);
  } else if (reach.value == 0) {
    output += "limit reached";
  } else {
    output += std::format("limit {}{} reached", reach.value, noun);
  }

  if (hits > 1) {
    output += std::format(" ({} times)", hits);
  }

  return output;
}

inline void reportCommandLimit(const LimitReach &reach) {
  writeText("telar: Limit reached: " + limitDescription(reach) + "\n", STDERR_FILENO);
}

}
