module telar.gui.features.machines;

import std;
import telar.base.ds;

namespace telar::gui::features::machines {

  namespace {

    enum class ExitStatus : std::uint8_t {
      command_not_executable = 126,
      command_not_found = 127,
      unreachable = 255,
    };

    template <std::size_t Count>
    bool mentionsAny(std::string_view text, const ds::Array<const char*, Count>& needles) noexcept {
      return std::ranges::any_of(needles, [text](const char* needle) {
        return text.contains(needle);
      });
    }

    // What the gateway program says of a machine that holds another key than its address pins, and
    // of one that does not admit this one.
    MachineError reachFailure(std::string_view text) noexcept {
      static constexpr ds::Array key_texts{"holds another key"};
      if (mentionsAny(text, key_texts)) {
        return MachineError::host_key_rejected;
      }

      static constexpr ds::Array pairing_texts{"is not paired"};
      if (mentionsAny(text, pairing_texts)) {
        return MachineError::authentication_failed;
      }

      return MachineError::endpoint_unavailable;
    }

    template <typename Resolve>
    runtime::cli::SocketLocation located(Resolve&& resolve) {
      try {
        return std::forward<Resolve>(resolve)();
      } catch (const std::invalid_argument&) {
        throw MachineFailure{MachineError::invalid_runtime_directory};
      }
    }

  }

  MachineError MachineConnectionPolicy::failure(MachineReachResult result) noexcept {
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
    case ExitStatus::unreachable:
      return reachFailure(result.standard_error);
    }

    return MachineError::endpoint_unavailable;
  }

  bool MachineConnectionPolicy::permanent(MachineError error) noexcept {
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
    case MachineError::invalid_id:
    case MachineError::invalid_label:
    case MachineError::invalid_color:
    case MachineError::invalid_program:
    case MachineError::invalid_profiles:
    case MachineError::incompatible_profiles:
    case MachineError::too_many:
    case MachineError::duplicate_id:
    case MachineError::duplicate_label:
    case MachineError::duplicate_destination:
    case MachineError::unknown_machine:
    case MachineError::endpoint_unavailable:
      break;
    }

    // A transient error, or one outside the enum.
    return false;
  }

  bool MachineConnectionPolicy::setupRepairs(MachineError error) noexcept {
    switch (error) {
    case MachineError::remote_program_missing:
    case MachineError::discovery_unreadable:
    case MachineError::remote_program_incompatible:
    case MachineError::remote_runtime_incompatible:
      return true;
    case MachineError::invalid_id:
    case MachineError::invalid_label:
    case MachineError::invalid_destination:
    case MachineError::invalid_color:
    case MachineError::invalid_program:
    case MachineError::invalid_profiles:
    case MachineError::incompatible_profiles:
    case MachineError::too_many:
    case MachineError::duplicate_id:
    case MachineError::duplicate_label:
    case MachineError::duplicate_destination:
    case MachineError::unknown_machine:
    case MachineError::host_key_rejected:
    case MachineError::authentication_failed:
    case MachineError::endpoint_unavailable:
    case MachineError::incompatible_schema:
    case MachineError::runtime_already_running:
    case MachineError::invalid_runtime_directory:
      break;
    }

    // An error setup does not repair, or one outside the enum.
    return false;
  }

  std::string_view MachineProfileMessages::failure(MachineError error) {
    return MachineFailure::description(error).valueOr(MachineFailure::name(error));
  }

  MachineRuntimeLocation MachineRuntimeLocation::explicitPath(std::string_view path) {
    return MachineRuntimeLocation{located([&] {
      return runtime::cli::SocketLocation::explicitPath(path);
    })};
  }

  std::string_view MachineRuntimeLocation::endpoint() const noexcept {
    return location_.path();
  }

  ds::Option<std::string_view> MachineRuntimeLocation::managedDirectory() const noexcept {
    return location_.managedDirectory();
  }

  MachineRuntimeLocation::MachineRuntimeLocation(const runtime::cli::SocketLocation& location) noexcept
      : location_(location) {}

  MachineRuntimeLocation MachineRuntimeLocation::resolveFrom(const runtime::EnvironmentSource& environment, std::uint32_t user) {
    return MachineRuntimeLocation{located([&] {
      return runtime::cli::SocketLocation::resolve({}, environment, user);
    })};
  }

}
