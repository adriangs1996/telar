#pragma once

#include "failure.hpp"
#include "field_rules.hpp"
#include "limits.hpp"
#include "memory/fixed_text.hpp"
#include "profile.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

class MachineProfiles {
public:
  static constexpr std::uint16_t plain_format_version = 1;
  static constexpr std::uint16_t extended_format_version = 2;

  [[nodiscard]] std::span<const MachineProfile> rows() const noexcept {
    return std::span{rows_}.first(length_);
  }

  [[nodiscard]] std::optional<std::string_view> localLabel() const noexcept {
    return local_label_.view().empty() ? std::nullopt : std::optional{local_label_.view()};
  }

  void relabelLocal(std::string_view label) {
    MachineFieldRules::label(label);
    local_label_.assign(label);
  }

  [[nodiscard]] std::optional<std::size_t> find(std::string_view label) const noexcept {
    const auto found = std::ranges::find(rows(), label, &MachineProfile::label);

    return found == rows().end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - rows().begin())};
  }

  [[nodiscard]] std::optional<std::size_t> findDestination(std::string_view destination) const noexcept {
    const auto found = std::ranges::find(rows(), destination, &MachineProfile::destination);

    return found == rows().end() ? std::nullopt : std::optional{static_cast<std::size_t>(found - rows().begin())};
  }

  void add(const MachineProfile &profile) {
    if (length_ == rows_.size()) {
      throw MachineFailure{MachineError::too_many};
    }

    requireFreeLabel(profile.label());
    for (const auto &existing : rows()) {
      if (existing.identity() == profile.identity()) {
        throw MachineFailure{MachineError::duplicate_id};
      }

      if (existing.destination() == profile.destination()) {
        throw MachineFailure{MachineError::duplicate_destination};
      }
    }

    rows_[length_] = profile;
    ++length_;
  }

  void remove(std::string_view label) {
    const auto position = require(label);
    for (auto index = position; index + 1 < length_; ++index) {
      rows_[index] = rows_[index + 1];
    }

    --length_;
  }

  void rename(std::string_view label, std::string_view replacement) {
    const auto position = require(label);
    if (label == replacement) {
      return;
    }

    requireFreeLabel(replacement);
    rows_[position].relabel(replacement);
  }

  void enable(std::string_view label, bool enabled) {
    rows_[require(label)].enable(enabled);
  }

  void recordLogin(std::string_view label, MachineAgent agent, MachineLogin login) {
    rows_[require(label)].recordLogin(agent, login);
  }

  void placeProgram(std::string_view label, std::string_view path) {
    rows_[require(label)].placeProgram(path);
  }

  [[nodiscard]] std::uint16_t version() const {
    for (const auto &profile : rows()) {
      if (profile.program() || std::ranges::any_of(machine_agents, [&](MachineAgent agent) {
            return profile.login(agent).has_value();
          })) {
        return extended_format_version;
      }
    }

    return plain_format_version;
  }

private:
  [[nodiscard]] std::size_t require(std::string_view label) const {
    const auto found = find(label);
    if (!found) {
      throw MachineFailure{MachineError::unknown_machine};
    }

    return *found;
  }

  void requireFreeLabel(std::string_view label) const {
    MachineFieldRules::label(label);
    if (find(label) || localLabel() == label) {
      throw MachineFailure{MachineError::duplicate_label};
    }
  }

  std::array<MachineProfile, MachineLimits::profiles> rows_;
  runtime::FixedText<MachineLimits::label_bytes> local_label_;
  std::size_t length_ = 0;
};

}
