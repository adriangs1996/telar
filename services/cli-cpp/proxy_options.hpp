#pragma once

#include "arguments.hpp"
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

  // Zig's `ProxyOptions.parse`, with its error names.
  static ProxyTrustOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2 || std::string_view{arguments[0]} != "trust") {
      usage("MissingProxyTrustAction");
    }

    ProxyTrustOptions options;
    const std::string_view action = arguments[1];
    if (action == "install") {
      options.action = ProxyTrustAction::install;
    } else if (action == "uninstall") {
      options.action = ProxyTrustAction::uninstall;
    } else if (action != "status") {
      usage("UnknownProxyTrustAction");
    }

    for (std::size_t index = 2; index < arguments.size(); index += 2) {
      const std::string_view option = arguments[index];
      if (option == "--ca-dir") {
        if (!options.directory.empty() || index + 1 >= arguments.size() || std::string_view{arguments[index + 1]}.empty()) {
          usage("InvalidProxyTrustDirectory");
        }

        options.directory = arguments[index + 1];
      } else if (option == "--linux") {
        const std::string_view backend = index + 1 < arguments.size() ? std::string_view{arguments[index + 1]} : std::string_view{};
        if (!options.linux_backend.empty() || (backend != "update-ca-certificates" && backend != "trust")) {
          usage("InvalidLinuxTrustBackend");
        }

        options.linux_backend = backend;
      } else {
        usage("UnknownProxyTrustOption");
      }
    }

    return options;
  }
};

}
