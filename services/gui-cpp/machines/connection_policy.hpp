#pragma once

#include "failure.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

struct MachineSshResult {
  std::optional<std::uint8_t> exit_status;
  std::string_view standard_error;
};

struct MachineConnectionPolicy {
  [[nodiscard]] static MachineError failure(MachineSshResult result) noexcept {
    if (!result.exit_status) {
      return MachineError::endpoint_unavailable;
    }

    if (result.standard_error.contains("telar protocol mismatch")) {
      return MachineError::remote_runtime_incompatible;
    }

    switch (static_cast<ExitStatus>(*result.exit_status)) {
    case ExitStatus::command_not_executable:
    case ExitStatus::command_not_found:
      return MachineError::remote_program_missing;
    case ExitStatus::ssh_failed:
      return sshFailure(result.standard_error);
    default:
      return MachineError::endpoint_unavailable;
    }
  }

  [[nodiscard]] static bool permanent(MachineError error) noexcept {
    switch (error) {
    case MachineError::host_key_rejected:
    case MachineError::authentication_failed:
    case MachineError::remote_program_missing:
    case MachineError::discovery_unreadable:
    case MachineError::remote_program_incompatible:
    case MachineError::remote_runtime_incompatible:
    case MachineError::incompatible_schema:
    case MachineError::runtime_already_running:
    case MachineError::invalid_runtime_directory:
    case MachineError::invalid_destination:
      return true;
    default:
      return false;
    }
  }

  [[nodiscard]] static bool setupRepairs(MachineError error) noexcept {
    switch (error) {
    case MachineError::remote_program_missing:
    case MachineError::discovery_unreadable:
    case MachineError::remote_program_incompatible:
    case MachineError::remote_runtime_incompatible:
      return true;
    default:
      return false;
    }
  }

private:
  enum class ExitStatus : std::uint8_t {
    command_not_executable = 126,
    command_not_found = 127,
    ssh_failed = 255,
  };

  static MachineError sshFailure(std::string_view text) noexcept {
    static constexpr std::array host_key_texts{"Host key verification failed", "REMOTE HOST IDENTIFICATION HAS CHANGED"};
    if (mentionsAny(text, host_key_texts)) {
      return MachineError::host_key_rejected;
    }

    static constexpr std::array authentication_texts{"Permission denied (", "Too many authentication failures"};
    if (mentionsAny(text, authentication_texts)) {
      return MachineError::authentication_failed;
    }

    return MachineError::endpoint_unavailable;
  }

  template <std::size_t Count>
  static bool mentionsAny(std::string_view text, const std::array<const char *, Count> &needles) noexcept {
    return std::ranges::any_of(needles, [text](const char *needle) {
      return text.contains(needle);
    });
  }
};

}
