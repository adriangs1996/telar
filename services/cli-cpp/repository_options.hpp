#pragma once

#include "command_io.hpp"
#include <optional>

namespace telar::runtime::cli {

struct RepositoryOptions {
  enum class Action {
    prepare,
    receive
  };
  Action action;
  std::optional<std::string_view> machine = std::nullopt;
  std::string_view from = "HEAD";
  std::optional<std::string_view> workspace = std::nullopt;
  std::string_view identity;
  std::string_view transport;
  std::string_view commit;
  std::string_view ref;
  std::uint64_t bytes = 0;
  bool json = false;

  static RepositoryOptions parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingRepositoryAction"};
    }

    const std::string_view action = words.front();
    if (action != "prepare" && action != "receive") {
      throw std::invalid_argument{"UnknownRepositoryAction"};
    }

    RepositoryOptions self{.action = action == "prepare" ? Action::prepare : Action::receive};
    Cursor cursor{words.subspan(1)};
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--json") {
        self.json = true;
        continue;
      }

      const auto value = cursor.take("MissingRepositoryOptionValue");
      if (arg == "--machine" && self.action == Action::prepare) {
        self.machine = value;
      } else if (arg == "--from" && self.action == Action::prepare) {
        self.from = value;
      } else if (arg == "--workspace") {
        self.workspace = value;
      } else if (arg == "--identity" && self.action == Action::receive) {
        self.identity = value;
      } else if (arg == "--transport" && self.action == Action::receive) {
        self.transport = value;
      } else if (arg == "--commit" && self.action == Action::receive) {
        self.commit = value;
      } else if (arg == "--ref" && self.action == Action::receive) {
        self.ref = value;
      } else if (arg == "--bytes" && self.action == Action::receive) {
        self.bytes = parseUnsigned<std::uint64_t>(value);
      } else {
        throw std::invalid_argument{"UnknownRepositoryOption"};
      }
    }

    if (self.action == Action::prepare && !self.machine) {
      throw std::invalid_argument{"MissingMachineLabel"};
    }

    return self;
  }
};

}
