#pragma once

#include "failure.hpp"
#include "field_rules.hpp"
#include "identity.hpp"
#include "limits.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::runtime::machines {

enum class MachineLogin : std::uint8_t {
  pending,
  done,
  failed,
};
enum class MachineAgent : std::uint8_t {
  claude,
  codex,
  pi,
  cursor,
  opencode,
};

inline constexpr std::array machine_agents{MachineAgent::claude, MachineAgent::codex, MachineAgent::pi, MachineAgent::cursor, MachineAgent::opencode};
inline constexpr std::array<std::string_view, machine_agents.size()> machine_agent_names{"claude", "codex", "pi", "cursor", "opencode"};
inline constexpr auto machine_login_names = std::to_array<std::string_view>({"pending", "done", "failed"});

struct MachineProfileFields {
  std::string_view label;
  std::string_view destination;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  std::optional<std::string_view> program = std::nullopt;
};

class MachineProfile {
public:
  [[nodiscard]] static MachineProfile create(MachineId identity, MachineProfileFields fields) {
    if (identity.value() == 0) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineFieldRules::label(fields.label);
    MachineFieldRules::profileDestination(fields.destination);
    MachineProfile profile;
    profile.identity_ = identity;
    profile.label_.assign(fields.label);
    profile.destination_.assign(fields.destination);
    profile.enabled_ = fields.enabled;
    if (fields.color) {
      MachineFieldRules::color(*fields.color);
      profile.color_.assign(*fields.color);
    }

    if (fields.program) {
      profile.placeProgram(*fields.program);
    }

    return profile;
  }

  [[nodiscard]] MachineId identity() const noexcept {
    return identity_;
  }

  [[nodiscard]] std::string_view label() const noexcept {
    return label_.view();
  }

  [[nodiscard]] std::string_view destination() const noexcept {
    return destination_.view();
  }

  [[nodiscard]] std::optional<std::string_view> color() const noexcept {
    return optional(color_.view());
  }

  [[nodiscard]] std::optional<std::string_view> program() const noexcept {
    return optional(program_.view());
  }

  [[nodiscard]] bool enabled() const noexcept {
    return enabled_;
  }

  void enable(bool enabled) noexcept {
    enabled_ = enabled;
  }

  void relabel(std::string_view label) {
    MachineFieldRules::label(label);
    label_.assign(label);
  }

  void placeProgram(std::string_view path) {
    MachineFieldRules::program(path);
    program_.assign(path);
  }

  void recordLogin(MachineAgent agent, std::optional<MachineLogin> login) {
    logins_.at(static_cast<std::size_t>(agent)) = login;
  }

  [[nodiscard]] std::optional<MachineLogin> login(MachineAgent agent) const {
    return logins_.at(static_cast<std::size_t>(agent));
  }

private:
  static std::optional<std::string_view> optional(std::string_view value) noexcept {
    return value.empty() ? std::nullopt : std::optional{value};
  }

  MachineId identity_;
  runtime::FixedText<MachineLimits::label_bytes> label_;
  runtime::FixedText<MachineLimits::destination_bytes> destination_;
  runtime::FixedText<MachineLimits::color_bytes> color_;
  runtime::FixedText<MachineLimits::program_bytes> program_;
  std::array<std::optional<MachineLogin>, machine_agents.size()> logins_{};
  bool enabled_ = true;
};

}
