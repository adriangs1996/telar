#pragma once

#include "failure.hpp"
#include "machines.hpp"
#include "profiles.hpp"
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui {

struct MachineOpening {
  [[nodiscard]] static std::optional<std::string_view> saved(const MachineProfiles &profiles, std::string_view label, std::string_view hostname) {
    if (const auto index = profiles.find(label)) {
      return profiles.rows()[*index].destination();
    }

    if (profiles.localLabel().value_or(hostname) == label) {
      return std::nullopt;
    }

    throw MachineFailure{MachineError::unknown_machine};
  }

  [[nodiscard]] static std::optional<Machines::Slot> admitted(const Machines &machines, std::string_view name) noexcept {
    const auto rows = machines.rows();
    for (std::size_t index = 1; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto &row = rows[index];
      if (row.used && (row.label.view() == name || row.destination.view() == name)) {
        return slot;
      }
    }

    return std::nullopt;
  }
};

}
