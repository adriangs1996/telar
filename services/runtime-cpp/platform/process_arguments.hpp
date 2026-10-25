#pragma once

#include "../agents/builtin_manifests.hpp"
#include "../agents/session_host.hpp"
#include <cstring>
#include <optional>

namespace telar::runtime {

inline std::string_view processBasename(std::string_view path) noexcept {
  const auto slash = path.find_last_of("/\\");
  return path.substr(slash == std::string_view::npos ? 0 : slash + 1);
}

class ProcessArguments {
public:
  explicit ProcessArguments(std::string_view arguments) noexcept
      : arguments_(arguments) {}

  static ProcessArguments fromMacos(std::span<const char> buffer) noexcept {
    if (buffer.size() <= sizeof(int)) {
      return ProcessArguments{{}};
    }

    int count = 0;
    std::memcpy(&count, buffer.data(), sizeof(count));
    std::string_view remaining{buffer.data() + sizeof(count), buffer.size() - sizeof(count)};
    const auto executable_end = remaining.find('\0');
    if (count <= 0 || executable_end == std::string_view::npos) {
      return ProcessArguments{{}};
    }

    const auto first_argument = remaining.find_first_not_of('\0', executable_end);
    if (first_argument == std::string_view::npos) {
      return ProcessArguments{{}};
    }

    remaining.remove_prefix(first_argument);
    std::size_t length = 0;
    for (int index = 0; index < count; ++index) {
      const auto end = remaining.find('\0', length);
      if (end == std::string_view::npos) {
        return ProcessArguments{{}};
      }

      length = end + 1;
    }

    return ProcessArguments{remaining.substr(0, length)};
  }

  AgentProvider provider(const AgentManifests &manifests, std::string_view command) const noexcept {
    auto detected = manifests.fromExecutable(processBasename(command));
    if (detected != AgentProvider::unknown) {
      return detected;
    }

    auto remaining = arguments_;
    const auto first = next(remaining);
    if (!first) {
      return AgentProvider::unknown;
    }

    detected = manifests.fromExecutable(processBasename(*first));
    if (detected != AgentProvider::unknown) {
      return detected;
    }
    if (!genericRuntime(command) && !genericRuntime(*first)) {
      return AgentProvider::unknown;
    }

    while (const auto argument = next(remaining)) {
      if (argument->starts_with('-')) {
        continue;
      }

      detected = manifests.fromExecutable(processBasename(*argument));
      return detected == AgentProvider::unknown ? manifests.fromPath(*argument) : detected;
    }

    return AgentProvider::unknown;
  }

  SessionHost sessionHost(AgentProvider provider) const noexcept {
    if (provider != AgentProvider::codex || arguments_.empty()) {
      return SessionHost::unknown;
    }

    auto host = SessionHost::shared_server;
    auto remaining = arguments_;
    while (const auto argument = next(remaining)) {
      if (isCodexBatchArgument(*argument)) {
        return SessionHost::unknown;
      }
      if (*argument == codex_pane_argument) {
        host = SessionHost::pane;
      }
    }

    return host;
  }

private:
  static std::optional<std::string_view> next(std::string_view &remaining) noexcept {
    const auto first = remaining.find_first_not_of('\0');
    if (first == std::string_view::npos) {
      return std::nullopt;
    }

    remaining.remove_prefix(first);
    const auto end = remaining.find('\0');
    const auto argument = remaining.substr(0, end);
    remaining = end == std::string_view::npos ? std::string_view{} : remaining.substr(end + 1);
    return argument;
  }

  static bool genericRuntime(std::string_view command) noexcept {
    auto name = processBasename(command);
    if (name.size() >= 4 && containsInsensitive(name.substr(name.size() - 4), ".exe")) {
      name.remove_suffix(4);
    }

    for (const std::string_view candidate : {"node", "bun", "deno"}) {
      if (name.size() == candidate.size() && containsInsensitive(name, candidate)) {
        return true;
      }
    }

    return false;
  }

  std::string_view arguments_;
};

}
