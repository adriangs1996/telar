module;
#include <cstdio>

#include <cstddef>
#include <cstdint>


#include <cstring>


#include <sys/un.h>

export module telar.gui.machines.discovery;

import std;

export import telar.client;
export import telar.machines;


export import telar.gui.text.json_unsigned_integer;


export import telar.gui.platform.notification_commands;
import telar.base.memory;
import telar.client.protocol;

// Interface: machines/failure.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
using telar::runtime::machines::MachineError;
using telar::runtime::machines::MachineFailure;
}

// Interface: machines/connection_policy.cppm
export {
namespace telar::gui {

struct MachineSshResult {
  std::optional<std::uint8_t> exit_status;
  std::string_view standard_error;
};

struct MachineConnectionPolicy {
  [[nodiscard]] inline static MachineError failure(MachineSshResult result) noexcept {
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

  [[nodiscard]] inline static bool permanent(MachineError error) noexcept {
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

  [[nodiscard]] inline static bool setupRepairs(MachineError error) noexcept {
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

  inline static MachineError sshFailure(std::string_view text) noexcept {
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
  inline static bool mentionsAny(std::string_view text, const std::array<const char *, Count> &needles) noexcept {
    return std::ranges::any_of(needles, [text](const char *needle) {
      return text.contains(needle);
    });
  }
};

}
}

// Interface: machines/discovery.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
using telar::runtime::machines::MachineDiscovery;
}

// Interface: machines/identity.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
using telar::runtime::machines::MachineIdentityRandom;
using telar::runtime::machines::MachineId;
}

// Interface: machines/limits.cppm
// Shared with the CLI: telar.machines defines it.
export namespace telar::gui {
using telar::runtime::machines::MachineLimits;
}

// Interface: machines/messages.cppm
export {
namespace telar::gui {

struct MachineProfileMessages {
  static constexpr std::string_view insecure_file = "machines.json must be a regular file only its owner can read and write (chmod 600)";
  static constexpr std::string_view edit_pending = "the previous machine change is still being saved";

  [[nodiscard]] inline static std::string_view failure(MachineError error) {
    switch (error) {
    case MachineError::unknown_machine:
      return "no saved machine has that label; see `telar machine list`";
    case MachineError::duplicate_label:
      return "that label is already taken, by a saved machine or by this machine";
    case MachineError::duplicate_destination:
      return "two saved machines cannot share one SSH destination";
    case MachineError::too_many:
      return "machines.json already holds the most machines it can";
    case MachineError::invalid_label:
      return "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit";
    case MachineError::invalid_color:
      return "colors are #RRGGBB or a theme role such as red or accent";
    case MachineError::invalid_destination:
      return "destinations are an ssh host alias or user@host, without spaces or a leading '-'";
    case MachineError::invalid_program:
      return "telar paths are absolute and hold only letters, digits, '/', '.', '_', '+' or '-'";
    case MachineError::invalid_profiles:
      return "machines.json is not a file this telar can read";
    case MachineError::incompatible_profiles:
      return "machines.json was written by a newer telar; update this one to read it";
    default:
      return MachineFailure::name(error);
    }
  }
};

}
}

// Interface: machines/runtime_location.cppm
export {
namespace telar::gui {

template <typename Environment>
concept MachineRuntimeEnvironment = requires(const Environment &environment, const char *name) {
  { environment(name) } -> std::same_as<std::optional<std::string_view>>;
};

class MachineRuntimeLocation {
public:
  template <MachineRuntimeEnvironment Environment>
  [[nodiscard]] inline static MachineRuntimeLocation resolve(const Environment &environment, std::uint32_t user) {
    for (const auto *name : {"TELAR_SOCKET", "TELAR_SOCKET_PATH"}) {
      if (const auto path = environment(name); path && !path->empty()) {
        return explicitPath(*path);
      }
    }

    if (const auto base = environment("XDG_RUNTIME_DIR"); base && !base->empty()) {
      return managed(*base, std::nullopt);
    }

    const auto temporary = environment("TMPDIR");

    return managed(temporary && !temporary->empty() ? *temporary : std::string_view{"/tmp"}, user);
  }

  [[nodiscard]] inline static MachineRuntimeLocation explicitPath(std::string_view path) {
    validate(path);
    MachineRuntimeLocation result;
    result.endpoint_.append(path);

    return result;
  }

  [[nodiscard]] inline std::string_view endpoint() const noexcept {
    return endpoint_.view();
  }

  [[nodiscard]] inline std::optional<std::string_view> managedDirectory() const noexcept {
    if (directory_bytes_ == 0) {
      return std::nullopt;
    }

    auto directory = endpoint();
    directory.remove_suffix(directory.size() - directory_bytes_);

    return directory;
  }

private:
  [[nodiscard]] inline static MachineRuntimeLocation managed(std::string_view base, std::optional<std::uint32_t> user) {
    MachineRuntimeLocation result;
    try {
      result.endpoint_.append(base);
      if (!base.ends_with('/')) {
        result.endpoint_.append("/");
      }

      result.endpoint_.append("telar");
      if (user) {
        result.endpoint_.append("-");
        result.endpoint_.appendDecimal(*user);
      }

      result.directory_bytes_ = result.endpoint_.view().size();
      result.endpoint_.append("/runtime.sock");
    } catch (const std::length_error &) {
      throw MachineFailure{MachineError::invalid_runtime_directory};
    }

    validate(result.endpoint());

    return result;
  }

  inline static void validate(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.contains('\0') || path.size() > platform::SocketLimits::path_bytes) {
      throw MachineFailure{MachineError::invalid_runtime_directory};
    }
  }

  BoundedText<platform::SocketLimits::path_bytes> endpoint_;
  std::size_t directory_bytes_ = 0;
};

}
}
