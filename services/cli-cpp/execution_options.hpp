#pragma once

#include "command_io.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>

namespace telar::runtime::cli {

struct ExecutionOptions {
  enum class Action {
    start,
    status,
    output,
    cancel,
    forget,
    list
  };
  static constexpr std::size_t max_arguments = 64;
  Action action = Action::start;
  std::uint64_t id = 0;
  std::uint64_t workspace = 0;
  std::string_view cwd;
  std::string_view socket;
  std::array<std::string_view, max_arguments> arguments{};
  std::size_t argument_count = 0;
  bool detach = false;
  bool json = false;
  bool stdin_open = true;
  std::uint32_t timeout_seconds = 0;
  std::uint64_t stdout_offset = 0;
  std::uint64_t stderr_offset = 0;

  static ExecutionOptions parse(Arguments words) {
    ExecutionOptions self;
    std::size_t index = 0;
    constexpr std::array names{"start", "status", "output", "cancel", "forget", "list"};
    if (!words.empty()) {
      for (std::size_t action = 0; action < names.size(); ++action) {
        if (words.front() == std::string_view{names[action]}) {
          self.action = static_cast<Action>(action);
          ++index;
          if (self.action != Action::start && self.action != Action::list) {
            if (index == words.size()) {
              throw std::invalid_argument{"MissingExecutionId"};
            }

            self.id = parseInteger<std::uint64_t>(words[index++]);
          }

          break;
        }
      }
    }

    for (; index < words.size(); ++index) {
      const std::string_view arg = words[index];
      if (arg == "--") {
        self.argument_count = words.size() - index - 1;
        if (self.argument_count > max_arguments) {
          throw std::invalid_argument{self.action == Action::start ? "InvalidExecutionArguments" : "InvalidExecutionOptions"};
        }

        for (std::size_t at = 0; at < self.argument_count; ++at) {
          self.arguments[at] = words[index + 1 + at];
        }

        break;
      }

      if (arg == "--detach") {
        self.detach = true;
      } else if (arg == "--json") {
        self.json = true;
      } else if (arg == "--no-stdin") {
        self.stdin_open = false;
      } else {
        const auto value = requireValue(words, index, "MissingExecutionOptionValue");
        if (arg == "--cwd") {
          self.cwd = value;
        } else if (arg == "--socket") {
          self.socket = value;
        } else if (arg == "--workspace") {
          self.workspace = parseInteger<std::uint64_t>(value);
          if (self.workspace == 0) {
            throw std::invalid_argument{"InvalidWorkspaceId"};
          }
        } else if (arg == "--id") {
          self.id = parseInteger<std::uint64_t>(value);
        } else if (arg == "--timeout") {
          self.timeout_seconds = parseInteger<std::uint32_t>(value);
        } else if (arg == "--stdout-offset") {
          self.stdout_offset = parseInteger<std::uint64_t>(value);
        } else if (arg == "--stderr-offset") {
          self.stderr_offset = parseInteger<std::uint64_t>(value);
        } else {
          throw std::invalid_argument{"UnknownExecutionOption"};
        }
      }
    }

    if (self.action == Action::start) {
      if (self.argument_count == 0) {
        throw std::invalid_argument{"InvalidExecutionArguments"};
      }

      if (self.json && !self.detach) {
        throw std::invalid_argument{"ForegroundExecutionUsesRawStreams"};
      }
    } else if ((self.action == Action::list ? self.id != 0 : self.id == 0) || self.argument_count != 0 || self.detach || !self.cwd.empty() || self.workspace != 0) {
      throw std::invalid_argument{"InvalidExecutionOptions"};
    }

    return self;
  }
};

}
