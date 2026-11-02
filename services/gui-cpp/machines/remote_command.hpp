#pragma once

#include "field_rules.hpp"
#include "limits.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui {

class MachineRemoteCommand {
  static constexpr std::string_view discovery_prefix = R"(/bin/sh -c 'printf "%s\n" "$HOME" "${SHELL:-/bin/sh}"; exec )";
  static constexpr std::string_view discovery_suffix = " server endpoint'";
  static constexpr std::string_view bridge_prefix = "exec ";
  static constexpr std::string_view bridge_suffix = " server bridge";

public:
  static constexpr std::size_t max_bytes = discovery_prefix.size() + MachineLimits::program_bytes + discovery_suffix.size();
  using Text = BoundedText<max_bytes>;

  [[nodiscard]] static Text discovery(std::optional<std::string_view> program = std::nullopt) {
    return format(discovery_prefix, program, discovery_suffix);
  }

  [[nodiscard]] static Text bridge(std::optional<std::string_view> program = std::nullopt) {
    return format(bridge_prefix, program, bridge_suffix);
  }

private:
  static Text format(std::string_view prefix, std::optional<std::string_view> program, std::string_view suffix) {
    if (program) {
      MachineFieldRules::program(*program);
    }

    Text command;
    command.append(prefix);
    command.append(program.value_or("telar"));
    command.append(suffix);

    return command;
  }
};

}
