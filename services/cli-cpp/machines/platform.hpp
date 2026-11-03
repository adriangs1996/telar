#pragma once

#include "../machine_ssh.hpp"
#include <map>
#include <set>

namespace telar::runtime::cli::machine {

struct Platform {
  std::string os;
  std::string arch;
  std::string libc;
  std::string home;
  std::string target;
  std::optional<std::string> installed;
  std::optional<std::string> node;
  std::set<std::string> tools;
  std::map<std::string, std::string> agents;

  static Platform parse(std::string_view output) {
    constexpr std::size_t max_output = 8 * 1024;
    if (output.size() > max_output) {
      throw CommandError{"MachineProbeUnreadable"};
    }

    Platform result;
    while (output.ends_with('\n')) {
      output.remove_suffix(1);
    }

    for (;;) {
      const auto end = output.find('\n');
      const auto line = output.substr(0, end);
      const auto equals = line.find('=');
      if (equals == std::string_view::npos) {
        throw CommandError{"MachineProbeUnreadable"};
      }

      const auto key = line.substr(0, equals);
      const auto value = line.substr(equals + 1);
      if (value.size() > MachineLimits::program_bytes || std::ranges::any_of(value, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
        throw CommandError{"MachineProbeUnreadable"};
      }

      const auto absolute = [&] {
        if (value.empty() || value.front() != '/') {
          throw CommandError{"MachineProbeUnreadable"};
        }

        return std::string{value};
      };
      if (key == "os") {
        if (value == "Linux") {
          result.os = "linux";
        } else if (value == "Darwin") {
          result.os = "macos";
        } else {
          throw CommandError{"UnsupportedMachineSystem"};
        }
      } else if (key == "arch") {
        if (value == "x86_64" || value == "amd64") {
          result.arch = "x86_64";
        } else if (value == "aarch64" || value == "arm64") {
          result.arch = "aarch64";
        } else {
          throw CommandError{"UnsupportedMachineArchitecture"};
        }
      } else if (key == "libc") {
        if (value != "gnu" && value != "musl") {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.libc = value;
      } else if (key == "home") {
        result.home = absolute();
      } else if (key == "target") {
        result.target = absolute();
      } else if (key == "installed") {
        result.installed = value;
      } else if (key == "node") {
        result.node = value;
      } else if (key == "tool") {
        if (value != "curl" && value != "tar" && value != "bash" && value != "node" && value != "npm") {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.tools.emplace(value);
      } else if (key == "agent") {
        const auto colon = value.find(':');
        const auto agent = value.substr(0, colon);
        if (colon == std::string_view::npos || std::ranges::find(machine_agent_names, agent) == machine_agent_names.end() || colon + 1 == value.size() || value[colon + 1] != '/') {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.agents[std::string{agent}] = value.substr(colon + 1);
      } else {
        throw CommandError{"MachineProbeUnreadable"};
      }

      if (end == std::string_view::npos) {
        break;
      }

      output.remove_prefix(end + 1);
    }

    if (result.os.empty() || result.arch.empty() || result.libc.empty() || result.home.empty() || result.target.empty()) {
      throw CommandError{"MachineProbeUnreadable"};
    }

    return result;
  }

  std::string assetName() const {
    return "telar-" + os + "-" + arch + (os == "linux" ? "-headless.tar.gz" : ".tar.gz");
  }
};

}
