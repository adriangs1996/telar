#pragma once

#include "command_io.hpp"
#include <optional>

namespace telar::runtime::cli {

struct RuntimeOptions {
  enum class Action {
    status,
    metrics,
    watch
  };
  Action action;
  bool json = false;
  bool proxy_only = false;
  std::optional<std::uint32_t> count = std::nullopt;
  std::optional<std::string_view> socket = std::nullopt;

  static RuntimeOptions parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"UnknownRuntimeAction"};
    }

    const std::string_view action = words.front();
    if (action != "status" && action != "metrics" && action != "watch") {
      throw std::invalid_argument{"UnknownRuntimeAction"};
    }

    RuntimeOptions self{.action = action == "status" ? Action::status : action == "metrics" ? Action::metrics
                                                                                            : Action::watch};
    Cursor cursor{words.subspan(1)};
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json" || (self.action == Action::watch && arg == "--jsonl")) {
        if (self.json) {
          throw std::invalid_argument{"DuplicateJsonOption"};
        }

        self.json = true;
      } else if (arg == "--count" && self.action == Action::watch) {
        if (self.count) {
          throw std::invalid_argument{"DuplicateCountOption"};
        }

        self.count = number<std::uint32_t>(cursor.take("MissingCount"), "InvalidCount");
        if (*self.count == 0) {
          throw std::invalid_argument{"InvalidCount"};
        }
      } else if (arg == "--socket") {
        if (self.socket) {
          throw std::invalid_argument{"DuplicateSocketOption"};
        }

        self.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownRuntimeOption"};
      }
    }

    return self;
  }
};

}
