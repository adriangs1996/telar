module;

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>


#include <algorithm>
#include <optional>
#include <string_view>


#include "telar_base/memory/fixed_text.hpp"
#include <span>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cstring>


#include <charconv>
#include <concepts>
#include <system_error>


#include <sys/un.h>

export module telar.gui.machines.discovery;

export import telar.client;


export import telar.gui.text.json_unsigned_integer;


export import telar.gui.platform.notification_commands;

// Interface: machines/failure.cppm
export {
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
  inline explicit MachineFailure(MachineError code)
      : std::runtime_error(name(code)),
        code_(code) {}

  [[nodiscard]] inline MachineError code() const noexcept {
    return code_;
  }

  [[nodiscard]] inline static const char *name(MachineError code) {
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
export {
namespace telar::gui {

template <std::size_t MaximumPathBytes>
class MachineDiscovery {
public:
  static constexpr std::size_t path_count = 3;
  static constexpr std::size_t max_output_bytes = (path_count * (MaximumPathBytes + 1)) + SchemaId{}.size() + 1;

  [[nodiscard]] inline static MachineDiscovery parse(std::string_view output) {
    if (output.size() > max_output_bytes) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    while (output.ends_with('\n')) {
      output.remove_suffix(1);
    }

    MachineDiscovery result;
    const std::array paths{&result.home_, &result.shell_, &result.endpoint_};
    for (auto *const path : paths) {
      const auto end = output.find('\n');
      if (end == std::string_view::npos) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }

      const auto text = output.substr(0, end);
      validatePath(text, path == &result.endpoint_);
      path->assign(text);
      output.remove_prefix(end + 1);
    }

    if (output.size() != result.schema_.size()) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    for (const auto character : output) {
      if (!asciiAlphanumeric(character)) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }
    }

    std::memcpy(result.schema_.data(), output.data(), result.schema_.size());

    return result;
  }

  [[nodiscard]] inline std::string_view home() const noexcept {
    return home_.view();
  }

  [[nodiscard]] inline std::string_view shell() const noexcept {
    return shell_.view();
  }

  [[nodiscard]] inline std::string_view endpoint() const noexcept {
    return endpoint_.view();
  }

  [[nodiscard]] inline const SchemaId &schema() const noexcept {
    return schema_;
  }

  [[nodiscard]] inline bool compatible(const SchemaId &expected = handshake::schema_id) const noexcept {
    return schema_ == expected;
  }

private:
  inline static bool asciiAlphanumeric(char character) noexcept {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9');
  }

  inline static void validatePath(std::string_view path, bool socket_path) {
    if (path.empty() || path.size() > MaximumPathBytes || path.front() != '/') {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_character = 0x7f;
    for (const auto character : path) {
      const auto byte = static_cast<unsigned char>(character);
      if (byte < first_printable || byte == delete_character || (socket_path && character == ':')) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }
    }
  }

  runtime::FixedText<MaximumPathBytes> home_;
  runtime::FixedText<MaximumPathBytes> shell_;
  runtime::FixedText<MaximumPathBytes> endpoint_;
  SchemaId schema_{};
};

}
}

// Interface: machines/identity.cppm
export {
namespace telar::gui {

template <typename Random>
concept MachineIdentityRandom = requires(Random &random, std::span<std::uint8_t> bytes) {
  { random.fill(bytes) } -> std::same_as<void>;
};

class MachineId {
public:
  static constexpr std::string_view prefix = "m-";
  static constexpr std::size_t hex_digits = 12;
  static constexpr std::size_t text_bytes = prefix.size() + hex_digits;
  static constexpr unsigned bits_per_digit = 4;
  static constexpr unsigned value_bits = hex_digits * bits_per_digit;
  static constexpr auto maximum_value = (std::uint64_t{1} << value_bits) - 1;

  [[nodiscard]] inline static MachineId fromRaw(std::uint64_t value) {
    if (value == 0 || value > maximum_value) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineId identity;
    identity.value_ = value;

    return identity;
  }

  [[nodiscard]] inline static MachineId parse(std::string_view text) {
    if (text.size() != text_bytes || !text.starts_with(prefix)) {
      throw MachineFailure{MachineError::invalid_id};
    }

    std::uint64_t value = 0;
    for (const char digit : text.substr(prefix.size())) {
      const auto index = digits.find(digit);
      if (index == std::string_view::npos) {
        throw MachineFailure{MachineError::invalid_id};
      }

      value = (value << bits_per_digit) | index;
    }

    return fromRaw(value);
  }

  template <MachineIdentityRandom Random>
  [[nodiscard]] inline static MachineId generate(Random &random) {
    constexpr unsigned bits_per_byte = 8;
    constexpr unsigned entropy_bits = sizeof(std::uint64_t) * bits_per_byte;
    for (;;) {
      std::array<std::uint8_t, sizeof(std::uint64_t)> bytes{};
      random.fill(bytes);
      std::uint64_t value = 0;
      for (std::size_t index = 0; index < bytes.size(); ++index) {
        value |= static_cast<std::uint64_t>(bytes[index]) << (index * bits_per_byte);
      }

      value >>= entropy_bits - value_bits;
      if (value != 0) {
        return fromRaw(value);
      }
    }
  }

  [[nodiscard]] inline BoundedText<text_bytes> format() const {
    BoundedText<text_bytes> text;
    text.append(prefix);
    for (std::size_t position = hex_digits; position != 0; --position) {
      const auto shift = (position - 1) * bits_per_digit;
      text.append(digits.substr((value_ >> shift) & digit_mask, 1));
    }

    return text;
  }

  [[nodiscard]] inline std::uint64_t value() const noexcept {
    return value_;
  }

  bool operator==(const MachineId &) const = default;

private:
  static constexpr std::string_view digits = "0123456789abcdef";
  static constexpr auto digit_mask = (std::uint64_t{1} << bits_per_digit) - 1;
  std::uint64_t value_ = 0;
};

}
}

// Interface: machines/limits.cppm
export {
namespace telar::gui {

struct MachineLimits {
  static constexpr std::size_t profiles = 16;
  static constexpr std::size_t window_slots = profiles + 1;
  static constexpr std::size_t label_bytes = 32;
  static constexpr std::size_t destination_bytes = 255;
  static constexpr std::size_t color_bytes = 24;
  static constexpr std::size_t program_bytes = 255;
  static constexpr std::size_t file_bytes = std::size_t{32} * 1024;
  static constexpr std::size_t failure_bytes = 256;
};

}
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
