#pragma once

#include "command_io.hpp"
#include <optional>

namespace telar::runtime::cli {

struct DiagnosticsOptions {
  enum class Action {
    logs,
    limits
  };
  enum class Component {
    all,
    runtime,
    client
  };
  static constexpr std::uint16_t default_lines = 100;
  static constexpr std::uint16_t max_lines = 10000;
  Action action;
  Component component = Component::all;
  std::optional<std::uint32_t> pid = std::nullopt;
  std::uint16_t lines = default_lines;
  bool json = false;
  std::optional<std::string_view> socket = std::nullopt;

  static DiagnosticsOptions parse(Arguments words) {
    if (words.empty() || (std::string_view{words.front()} != "logs" && std::string_view{words.front()} != "limits")) {
      throw std::invalid_argument{"UnknownDiagnosticsAction"};
    }

    DiagnosticsOptions self{.action = std::string_view{words.front()} == "logs" ? Action::logs : Action::limits};
    Cursor cursor{words.subspan(1)};
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--component" && self.action == Action::logs) {
        const auto value = cursor.take("MissingComponent");
        if (value != "all" && value != "runtime" && value != "client") {
          throw std::invalid_argument{"InvalidComponent"};
        }

        self.component = value == "all" ? Component::all : value == "runtime" ? Component::runtime
                                                                              : Component::client;
      } else if (arg == "--pid" && !self.pid && self.action == Action::logs) {
        self.pid = number<std::uint32_t>(cursor.take("MissingPid"), "InvalidPid");
        if (*self.pid == 0) {
          throw std::invalid_argument{"InvalidPid"};
        }
      } else if (arg == "--lines" && self.action == Action::logs) {
        self.lines = number<std::uint16_t>(cursor.take("MissingLineCount"), "InvalidLineCount");
        if (self.lines == 0 || self.lines > max_lines) {
          throw std::invalid_argument{"InvalidLineCount"};
        }
      } else if (arg == "--json" && !self.json) {
        self.json = true;
      } else if (arg == "--socket" && !self.socket) {
        self.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownDiagnosticsOption"};
      }
    }

    return self;
  }
};

}
