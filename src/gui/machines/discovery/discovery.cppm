module;
#include "tbc/annotations.hpp"

export module telar.gui.machines.discovery;

import std;

export import telar.machines;

import telar.platform.paths;

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
      [[nodiscard]] static MachineError failure(MachineSshResult result) noexcept;

      [[nodiscard]] static bool permanent(MachineError error) noexcept;

      [[nodiscard]] static bool setupRepairs(MachineError error) noexcept;
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

      [[nodiscard]] static std::string_view failure(MachineError error);
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
      [[nodiscard]] TBC_GENERIC static MachineRuntimeLocation resolve(const Environment& environment, std::uint32_t user) {
        const Lookup<Environment> lookup{environment};

        return resolveFrom(lookup, user);
      }

      [[nodiscard]] static MachineRuntimeLocation explicitPath(std::string_view path);

      [[nodiscard]] std::string_view endpoint() const noexcept;

      [[nodiscard]] std::optional<std::string_view> managedDirectory() const noexcept;

    private:
      // The caller's environment behind the source SocketLocation reads.
      template <MachineRuntimeEnvironment Environment>
      class TBC_GENERIC Lookup final : public runtime::EnvironmentSource {
      public:
        explicit Lookup(const Environment& source) noexcept
            : source_(source) {}

        [[nodiscard]] std::string_view lookup(const char* name) const override {
          return source_(name).value_or(std::string_view{});
        }

      private:
        const Environment& source_;
      };

      explicit MachineRuntimeLocation(const runtime::cli::SocketLocation& location) noexcept;

      [[nodiscard]] static MachineRuntimeLocation resolveFrom(const runtime::EnvironmentSource& environment, std::uint32_t user);

      runtime::cli::SocketLocation location_;
    };

  }
}
