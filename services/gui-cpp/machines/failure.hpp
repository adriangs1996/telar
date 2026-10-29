#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>

namespace telar::gui {

enum class MachineError : std::uint8_t {
  invalid_id,
  invalid_label,
  invalid_destination,
  invalid_color,
  invalid_program,
  invalid_profiles,
  incompatible_profiles,
  too_many,
  duplicate_id,
  duplicate_label,
  duplicate_destination,
  unknown_machine,
  discovery_unreadable,
  host_key_rejected,
  authentication_failed,
  remote_program_missing,
  remote_program_incompatible,
  remote_runtime_incompatible,
  endpoint_unavailable,
  incompatible_schema,
  runtime_already_running,
  invalid_runtime_directory,
};

class MachineFailure final : public std::runtime_error {
public:
  explicit MachineFailure(MachineError code)
      : std::runtime_error(name(code)),
        code_(code) {}

  [[nodiscard]] MachineError code() const noexcept {
    return code_;
  }

  [[nodiscard]] static const char *name(MachineError code) {
    static constexpr std::array names{
        "InvalidMachineId",
        "InvalidMachineLabel",
        "InvalidRemoteDestination",
        "InvalidMachineColor",
        "InvalidRemoteTelarPath",
        "InvalidMachineProfiles",
        "IncompatibleMachineProfiles",
        "TooManyMachines",
        "DuplicateMachineId",
        "DuplicateMachineLabel",
        "DuplicateMachineDestination",
        "UnknownMachine",
        "RemoteDiscoveryUnreadable",
        "SshHostKeyRejected",
        "SshAuthenticationFailed",
        "RemoteTelarMissing",
        "RemoteTelarIncompatible",
        "RemoteRuntimeIncompatible",
        "RemoteEndpointUnavailable",
        "IncompatibleSchema",
        "RuntimeAlreadyRunning",
        "InvalidRuntimeDirectory",
    };

    return names.at(static_cast<std::size_t>(code));
  }

private:
  MachineError code_;
};

}
