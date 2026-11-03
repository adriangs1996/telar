#pragma once

#include <array>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::cli {

enum class ServerAction {
  run,
  stop,
  endpoint,
  bridge,
  help
};
enum class ServerMode {
  foreground,
  background,
  daemonized
};

struct ServerOptions {
  ServerAction action = ServerAction::run;
  ServerMode mode = ServerMode::foreground;
  std::string_view socket;
  std::string_view history;
  std::string_view session;
  std::string_view trace;
  std::string_view config;
  std::string_view profile;
  std::array<std::string_view, 64> engine_arguments;
  std::size_t engine_argument_count = 0;
  bool fresh = false;
  bool no_config = false;
  bool persist_session = true;
  bool resume_agents = true;

  static ServerOptions parse(std::span<char *const> arguments) {
    ServerOptions options;
    bool action_selected = false;
    if (!arguments.empty() && std::string_view{arguments.front()} == "server") {
      arguments = arguments.subspan(1);
    }

    for (std::size_t index = 0; index < arguments.size(); ++index) {
      const std::string_view argument = arguments[index];
      const auto value = [&]() -> std::string_view {
        if (++index == arguments.size()) {
          throw std::invalid_argument{"Missing server option value"};
        }

        return arguments[index];
      };
      if (argument == "stop" || argument == "endpoint" || argument == "bridge") {
        if (action_selected) {
          throw std::invalid_argument{"Duplicate server action"};
        }

        action_selected = true;
        options.action = argument == "stop" ? ServerAction::stop : argument == "endpoint" ? ServerAction::endpoint
                                                                                          : ServerAction::bridge;
      } else if (argument == "--help") {
        options.action = ServerAction::help;
      } else if (argument == "--socket") {
        setOnce(options.socket, value());
      } else if (argument == "--history") {
        setOnce(options.history, value());
      } else if (argument == "--session") {
        setOnce(options.session, value());
      } else if (argument == "--trace") {
        setOnce(options.trace, value());
      } else if (argument == "--config") {
        if (options.no_config) {
          throw std::invalid_argument{"Conflicting configuration options"};
        }
        setOnce(options.config, value());
      } else if (argument == "--profile") {
        setOnce(options.profile, value());
      } else if (argument == "--engine-arg") {
        if (options.engine_argument_count == options.engine_arguments.size()) {
          throw std::invalid_argument{"Too many engine arguments"};
        }

        options.engine_arguments[options.engine_argument_count++] = value();
      } else if (argument == "--no-session") {
        options.persist_session = false;
      } else if (argument == "--no-resume") {
        options.resume_agents = false;
      } else if (argument == "--no-config") {
        if (!options.config.empty()) {
          throw std::invalid_argument{"Conflicting configuration options"};
        }
        setFlag(options.no_config);
      } else if (argument == "--fresh") {
        setFlag(options.fresh);
      } else if (argument == "--background" || argument == "--daemonized") {
        if (options.mode != ServerMode::foreground) {
          throw std::invalid_argument{"Conflicting server modes"};
        }

        options.mode = argument == "--background" ? ServerMode::background : ServerMode::daemonized;
      } else {
        throw std::invalid_argument{"Unknown server option"};
      }
    }

    if (options.fresh && options.action != ServerAction::run) {
      throw std::invalid_argument{"Fresh session requires the run action"};
    }
    if (options.action == ServerAction::stop && options.mode != ServerMode::foreground) {
      throw std::invalid_argument{"Conflicting server action"};
    }
    if (options.no_config && !options.profile.empty()) {
      throw std::invalid_argument{"A profile requires configuration"};
    }

    return options;
  }

private:
  static void setOnce(std::string_view &destination, std::string_view value) {
    if (!destination.empty() || value.empty()) {
      throw std::invalid_argument{"Duplicate or empty server option"};
    }

    destination = value;
  }

  static void setFlag(bool &flag) {
    if (flag) {
      throw std::invalid_argument{"Duplicate server option"};
    }

    flag = true;
  }
};

}
