#pragma once

#include <cstdint>
#include <exception>
#include <span>
#include <string_view>

// The plain types the wire protocol shares with the platform layer: what a process launches
// with, the size of its terminal and why a request failed. They carry no codec, so a library
// that starts processes uses them without depending on the protocol; the protocol's schemas
// describe them on the wire.
namespace telar {

  using Byte = std::uint8_t;

  // | `TerminalSize` | `cols:u16, rows:u16, cell_width_px:u16, cell_height_px:u16` |
  struct TerminalSize {
    std::uint16_t cols;
    std::uint16_t rows;
    std::uint16_t cell_width_px;
    std::uint16_t cell_height_px;

    bool operator==(const TerminalSize&) const noexcept = default;
  };

  enum class EnvironmentMode : Byte {
    inherit_runtime = 0,
    replace = 1,
  };

  struct EnvironmentEntry {
    std::string_view name{};
    std::string_view value{};
  };

  struct Launch {
    std::string_view cwd{};
    std::uint64_t cwd_source = 0;
    std::span<const std::string_view> arguments{};
    EnvironmentMode environment_mode = EnvironmentMode::inherit_runtime;
    std::span<const EnvironmentEntry> environment{};
  };

  enum class FailureCode : std::uint16_t {
    pane_not_found = 1,
    invalid_request = 2,
    spawn_failed = 3,
    permission_denied = 4,
    resource_limit = 5,
    internal = 6,
    workspace_not_found = 7,
    tab_not_found = 8,
    agent_blocked = 9,
    pane_exited = 10,
    worktree_not_found = 11,
    pane_focused = 12,
    prompt_rate_limited = 13,
    agent_not_working = 14,
    interrupt_unsupported = 15,
    foreign_process = 16,
  };

}

namespace telar::runtime {

  class RequestError final : public std::exception {
  public:
    inline explicit RequestError(FailureCode code, const char* message) noexcept
        : code_(code),
          message_(message) {}

    inline FailureCode code() const noexcept {
      return code_;
    }

    inline const char* what() const noexcept override {
      return message_;
    }

  private:
    FailureCode code_;
    const char* message_;
  };

}
