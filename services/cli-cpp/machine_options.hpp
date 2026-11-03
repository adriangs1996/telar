#pragma once

#include <algorithm>
#include <array>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::cli {

struct MachineOptions {
  enum class Action {
    add,
    remove,
    rename,
    enable,
    disable,
    list,
    check,
    setup,
    receive_config
  };
  Action action;
  std::string_view label;
  std::string_view value;
  std::optional<std::string_view> color;
  std::optional<std::string_view> new_label;
  std::optional<std::string_view> binary;
  bool disabled = false;
  bool check = false;
  bool json = false;
  bool setup = false;
  bool confirm = false;
  std::array<bool, 3> skip{};

  static MachineOptions parse(std::span<char *const> args) {
    if (args.empty()) {
      throw std::invalid_argument{"MissingMachineAction"};
    }

    static constexpr std::array<std::string_view, 9> names{"add", "remove", "rename", "enable", "disable", "list", "check", "setup", "receive-config"};
    const auto found = std::ranges::find(names, std::string_view{args.front()});
    if (found == names.end()) {
      throw std::invalid_argument{"UnknownMachineAction"};
    }

    MachineOptions result{.action = static_cast<Action>(found - names.begin())};
    const auto action = result.action;
    const std::size_t positional = action == Action::list || action == Action::receive_config ? 0 : action == Action::add || action == Action::rename ? 2
                                                                                                                                                      : 1;
    if (action == Action::receive_config && args.size() != 1) {
      throw std::invalid_argument{"UnknownMachineOption"};
    }

    if (args.size() < positional + 1) {
      throw std::invalid_argument{"MissingMachineArgument"};
    }

    if (positional != 0) {
      result.label = args[1];
    }

    if (positional == 2) {
      result.value = args[2];
    }

    for (std::size_t index = positional + 1; index < args.size(); ++index) {
      const std::string_view word = args[index];
      const bool takes_setup = action == Action::add || action == Action::setup;
      const auto value = [&]() -> std::string_view {
        if (++index == args.size()) {
          throw std::invalid_argument{"MissingMachineArgument"};
        }

        return args[index];
      };
      if (word == "--json" && (action == Action::list || action == Action::check || takes_setup)) {
        result.json = true;
      } else if (word == "--setup" && action == Action::add) {
        result.setup = true;
      } else if (word == "--confirm" && action == Action::setup) {
        result.confirm = true;
      } else if (word == "--label" && action == Action::setup) {
        result.new_label = value();
      } else if (word == "--binary" && takes_setup) {
        result.binary = value();
      } else if (word == "--skip" && takes_setup) {
        auto names = value();
        do {
          const auto end = names.find(',');
          const auto name = names.substr(0, end);
          if (name == "agents") {
            result.skip[0] = true;
          } else if (name == "config") {
            result.skip[1] = true;
          } else if (name == "login") {
            result.skip[2] = true;
          } else {
            throw std::invalid_argument{"UnknownSetupSkip"};
          }

          if (end == std::string_view::npos) {
            break;
          }

          names.remove_prefix(end + 1);
        } while (true);
      } else if (word == "--color" && action == Action::add) {
        if (result.color) {
          throw std::invalid_argument{"DuplicateColorOption"};
        }

        if (++index == args.size()) {
          throw std::invalid_argument{"MissingMachineColor"};
        }

        result.color = args[index];
      } else if (word == "--disabled" && action == Action::add) {
        result.disabled = true;
      } else if (word == "--check" && action == Action::add) {
        result.check = true;
      } else {
        throw std::invalid_argument{"UnknownMachineOption"};
      }
    }

    if (action == Action::add && !result.setup && (result.binary || std::ranges::any_of(result.skip, [](bool value) { return value; }))) {
      throw std::invalid_argument{"SetupOptionWithoutSetup"};
    }

    return result;
  }
};

}
