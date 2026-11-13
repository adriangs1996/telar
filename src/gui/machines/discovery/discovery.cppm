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
import telar.platform;
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
      inline static bool mentionsAny(std::string_view text, const std::array<const char*, Count>& needles) noexcept {
        return std::ranges::any_of(needles, [text](const char* needle) {
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
  using telar::runtime::machines::MachineId;
  using telar::runtime::machines::MachineIdentityRandom;
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
      static constexpr std::string_view insecure_file = MachineFailure::insecure_file;
      static constexpr std::string_view edit_pending = "the previous machine change is still being saved";

      [[nodiscard]] inline static std::string_view failure(MachineError error) {
        return MachineFailure::description(error).value_or(MachineFailure::name(error));
      }
    };

  }
}

// Interface: machines/runtime_location.cppm
export {
  namespace telar::gui {

    template <typename Environment>
    concept MachineRuntimeEnvironment = requires(const Environment& environment, const char* name) {
      { environment(name) } -> std::same_as<std::optional<std::string_view>>;
    };

    // Where this machine's runtime listens, found as the runtime and the CLI find it.
    class MachineRuntimeLocation {
    public:
      template <MachineRuntimeEnvironment Environment>
      [[nodiscard]] inline static MachineRuntimeLocation resolve(const Environment& environment, std::uint32_t user) {
        const Lookup<Environment> lookup{environment};

        return located([&] {
          return runtime::cli::SocketLocation::resolve({}, lookup, user);
        });
      }

      [[nodiscard]] inline static MachineRuntimeLocation explicitPath(std::string_view path) {
        return located([&] {
          return runtime::cli::SocketLocation::explicitPath(path);
        });
      }

      [[nodiscard]] inline std::string_view endpoint() const noexcept {
        return location_.path();
      }

      [[nodiscard]] inline std::optional<std::string_view> managedDirectory() const noexcept {
        return location_.managedDirectory();
      }

    private:
      template <MachineRuntimeEnvironment Environment>
      struct Lookup {
        const Environment& source;

        [[nodiscard]] inline std::string_view lookup(const char* name) const {
          return source(name).value_or(std::string_view{});
        }
      };

      inline explicit MachineRuntimeLocation(const runtime::cli::SocketLocation& location) noexcept
          : location_(location) {}

      template <typename Resolve>
      [[nodiscard]] inline static MachineRuntimeLocation located(Resolve&& resolve) {
        try {
          return MachineRuntimeLocation{resolve()};
        } catch (const std::invalid_argument&) {
          throw MachineFailure{MachineError::invalid_runtime_directory};
        }
      }

      runtime::cli::SocketLocation location_;
    };

  }
}
