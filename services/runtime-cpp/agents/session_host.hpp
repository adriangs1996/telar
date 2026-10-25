#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>

namespace telar::runtime {

enum class SessionHost {
  unknown,
  pane,
  shared_server
};

inline constexpr std::string_view codex_pane_argument = "--no-daemon";
inline constexpr std::array codex_batch_arguments{
    "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "plugin",
    "app-server", "remote-control", "app", "completion", "update", "doctor",
    "sandbox", "debug", "apply", "a", "queue", "archive", "delete",
    "migrate-rollouts", "unarchive", "cloud", "exec-server", "features", "agents",
    "help", "--help", "-h", "--version", "-V"};

inline bool isCodexBatchArgument(std::string_view argument) noexcept {
  return std::ranges::any_of(codex_batch_arguments, [argument](std::string_view candidate) { return argument == candidate; });
}

}
