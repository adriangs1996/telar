#pragma once

#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::cli {

enum class ProxyTrustAction { install,
                              uninstall,
                              status };

struct ProxyTrustOptions {
  ProxyTrustAction action = ProxyTrustAction::status;
  std::string_view directory;
  std::string_view linux_backend;

  static ProxyTrustOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2 || std::string_view{arguments[0]} != "trust") {
      throw std::invalid_argument{"Expected proxy trust install|uninstall|status"};
    }

    ProxyTrustOptions options;
    const std::string_view action = arguments[1];
    if (action == "install") {
      options.action = ProxyTrustAction::install;
    } else if (action == "uninstall") {
      options.action = ProxyTrustAction::uninstall;
    } else if (action != "status") {
      throw std::invalid_argument{"Unknown proxy trust action"};
    }

    for (std::size_t index = 2; index < arguments.size(); index += 2) {
      const std::string_view option = arguments[index];
      if (index + 1 == arguments.size()) {
        throw std::invalid_argument{"Missing proxy trust option value"};
      }

      const std::string_view value = arguments[index + 1];
      if (option == "--ca-dir" && options.directory.empty() && !value.empty()) {
        options.directory = value;
      } else if (option == "--linux" && options.linux_backend.empty() && (value == "update-ca-certificates" || value == "trust")) {
        options.linux_backend = value;
      } else {
        throw std::invalid_argument{"Invalid proxy trust option"};
      }
    }

    return options;
  }
};

}
