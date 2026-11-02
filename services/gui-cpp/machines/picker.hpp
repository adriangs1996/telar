#pragma once

#include "machines.hpp"
#include "palette/ranked_matches.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

struct MachinePicker {
  using Matches = RankedMatches<MachineToken, Machines::capacity>;

  enum class Intent : std::uint8_t {
    none,
    add,
    select,
    setup,
    enable,
    disable,
  };

  [[nodiscard]] static Matches collect(const Machines &machines, std::string_view query) {
    Matches matches;
    for (std::size_t index = 0; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto &row = machines.row(slot);
      if (!row.used) {
        continue;
      }

      auto score = runtime::historyScore(row.label.view(), query);
      if (!score) {
        score = runtime::historyScore(row.destination.view(), query);
      }

      if (score) {
        matches.addScored(machines.token(slot), *score);
      }
    }

    return matches;
  }

  [[nodiscard]] static Intent choose(const Machines &machines, std::optional<MachineToken> chosen, bool alternate) {
    if (!chosen) {
      return Intent::add;
    }

    if (!machines.contains(*chosen)) {
      return Intent::none;
    }

    if (chosen->slot == Machines::local_slot) {
      return alternate ? Intent::none : Intent::select;
    }

    const auto &row = machines.row(chosen->slot);
    if (!alternate && row.needs_setup) {
      return Intent::setup;
    }

    if (alternate || !row.enabled) {
      return row.enabled ? Intent::disable : Intent::enable;
    }

    return Intent::select;
  }
};

}
