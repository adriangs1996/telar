#pragma once

#include "cli_install.hpp"
#include <algorithm>
#include <optional>
#include <vector>

namespace telar::runtime::cli {

struct WindowOptions {
  std::optional<std::string> config;
  std::optional<std::string> profile;
  std::optional<std::string> theme;
  std::optional<std::string> remote;
  std::optional<std::string> machine;
  bool no_config = false;
  bool fresh = false;
  bool login_shell = false;
  std::vector<std::string> command;

  static std::string canonicalTheme(std::string_view name) {
    std::string text{name};
    for (auto &byte : text) {
      if (byte >= 'A' && byte <= 'Z') {
        byte += 'a' - 'A';
      }
    }

    static constexpr auto aliases = std::to_array<std::pair<std::string_view, std::string_view>>({{"osaka-jade", "shade"}, {"osaka_jade", "shade"}, {"osakajade", "shade"}, {"catppuccin-mocha", "catppuccin"}, {"mocha", "catppuccin"}, {"tokyonight", "tokyo-night"}, {"tokyo_night", "tokyo-night"}, {"kanagawa-wave", "kanagawa"}, {"kanagawa_wave", "kanagawa"}, {"kanagawa_dragon", "kanagawa-dragon"}, {"default", "terminal"}});
    for (const auto &[alias, canonical] : aliases) {
      if (text == alias) {
        return std::string{canonical};
      }
    }

    static constexpr auto names = std::to_array<std::string_view>({"shade", "vesper", "catppuccin", "tokyo-night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-dragon", "terminal", "cybervenom"});
    if (std::ranges::find(names, text) == names.end()) {
      throw std::invalid_argument{"UnknownTheme"};
    }

    return text;
  }

  static WindowOptions parse(std::span<char *const> input, bool gui = false) {
    constexpr std::size_t maximum_arguments = 64;
    WindowOptions result;
    if (gui && input.size() > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    std::vector<std::string_view> args;
    for (const std::string_view word : input) {
      if (gui && word == "--login-shell") {
        result.login_shell = true;
      } else {
        args.push_back(word);
      }
    }

    std::size_t index = 0;
    for (; index < args.size(); ++index) {
      const auto word = args[index];
      if (word == "--") {
        if (++index == args.size()) {
          throw std::invalid_argument{"MissingCommand"};
        }

        break;
      }

      if (word == "--fresh") {
        if (result.fresh) {
          throw std::invalid_argument{"DuplicateFreshOption"};
        }

        result.fresh = true;
        continue;
      }

      if (word == "--no-config") {
        if (result.no_config || result.config) {
          throw std::invalid_argument{"DuplicateConfigOption"};
        }

        result.no_config = true;
        continue;
      }

      const auto equals = word.find('=');
      const auto flag = word.substr(0, equals);
      std::optional<std::string> *value = nullptr;
      const char *missing = nullptr;
      const char *duplicate = nullptr;
      if (flag == "--config") {
        value = &result.config;
        missing = "MissingConfigPath";
        duplicate = "DuplicateConfigOption";
      } else if (flag == "--profile") {
        value = &result.profile;
        missing = "MissingProfileName";
        duplicate = "DuplicateProfileOption";
      } else if (flag == "--theme") {
        value = &result.theme;
        missing = "MissingThemeName";
        duplicate = "DuplicateThemeOption";
      } else if (flag == "--remote") {
        value = &result.remote;
        missing = "MissingRemoteDestination";
        duplicate = "DuplicateRemoteOption";
      } else if (flag == "--machine") {
        value = &result.machine;
        missing = "MissingMachineLabel";
        duplicate = "DuplicateMachineOption";
      } else {
        break;
      }

      if (*value || (flag == "--config" && result.no_config)) {
        throw std::invalid_argument{duplicate};
      }

      std::string_view text;
      if (equals != std::string_view::npos) {
        text = word.substr(equals + 1);
        if (text.empty() && flag != "--theme") {
          throw std::invalid_argument{missing};
        }
      } else {
        if (++index == args.size()) {
          throw std::invalid_argument{missing};
        }

        text = args[index];
      }

      *value = flag == "--theme" ? canonicalTheme(text) : std::string{text};
    }

    if (args.size() - index > maximum_arguments) {
      throw std::invalid_argument{"a command telar launches takes at most 64 arguments"};
    }

    for (; index < args.size(); ++index) {
      result.command.emplace_back(args[index]);
    }

    if (result.no_config && result.profile) {
      throw std::invalid_argument{"ProfileWithoutConfig"};
    }

    if (result.fresh && result.remote) {
      throw std::invalid_argument{"FreshWithRemote"};
    }

    if (result.machine && result.remote) {
      throw std::invalid_argument{"MachineWithRemote"};
    }

    return result;
  }
};

}
