#pragma once

#include "failure.hpp"
#include "platform/socket_limits.hpp"
#include "text/bounded_text.hpp"
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <typename Environment>
concept MachineRuntimeEnvironment = requires(const Environment &environment, const char *name) {
  { environment(name) } -> std::same_as<std::optional<std::string_view>>;
};

class MachineRuntimeLocation {
public:
  template <MachineRuntimeEnvironment Environment>
  [[nodiscard]] static MachineRuntimeLocation resolve(const Environment &environment, std::uint32_t user) {
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

  [[nodiscard]] static MachineRuntimeLocation explicitPath(std::string_view path) {
    validate(path);
    MachineRuntimeLocation result;
    result.endpoint_.append(path);

    return result;
  }

  [[nodiscard]] std::string_view endpoint() const noexcept {
    return endpoint_.view();
  }

  [[nodiscard]] std::optional<std::string_view> managedDirectory() const noexcept {
    if (directory_bytes_ == 0) {
      return std::nullopt;
    }

    auto directory = endpoint();
    directory.remove_suffix(directory.size() - directory_bytes_);

    return directory;
  }

private:
  [[nodiscard]] static MachineRuntimeLocation managed(std::string_view base, std::optional<std::uint32_t> user) {
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

  static void validate(std::string_view path) {
    if (path.empty() || path.front() != '/' || path.contains('\0') || path.size() > platform::SocketLimits::path_bytes) {
      throw MachineFailure{MachineError::invalid_runtime_directory};
    }
  }

  BoundedText<platform::SocketLimits::path_bytes> endpoint_;
  std::size_t directory_bytes_ = 0;
};

}
