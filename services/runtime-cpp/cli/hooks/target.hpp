#pragma once

#include "../../platform/process_environment.hpp"
#include "../../text/decimal.hpp"
#include "session.hpp"
#include <charconv>

namespace telar::runtime::cli::hooks {

inline std::optional<std::uint64_t> unsignedValue(std::string_view value) noexcept {
  return unsignedDecimal<std::uint64_t>(value);
}

template <EnvironmentLookup Environment>
std::optional<PaneTarget> paneTarget(const Environment &environment, AgentProvider provider) noexcept {
  const auto pane = unsignedValue(environment.lookup("TELAR_PANE_ID"));
  const auto generation = unsignedValue(environment.lookup("TELAR_PANE_GENERATION"));
  if (!pane || *pane == 0 || !generation) {
    return std::nullopt;
  }

  return PaneTarget{.pane_id = *pane, .generation = *generation, .provider = provider};
}

}
