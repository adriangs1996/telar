#pragma once

#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::runtime::diagnostics {

struct LogName {
  enum class Role {
    runtime,
    client
  };

  std::string_view endpoint;
  Role role;
  std::uint32_t process;
  bool rotated;

  static std::optional<LogName> parse(std::string_view name) noexcept {
    const bool rotated = name.ends_with(".log.1");
    if (rotated) {
      name.remove_suffix(2);
    }

    if (!name.ends_with(".log")) {
      return std::nullopt;
    }

    name.remove_suffix(4);
    const auto dash = name.rfind('-');
    if (dash == std::string_view::npos) {
      return std::nullopt;
    }

    const auto digits = name.substr(dash + 1);
    if (digits.empty() || digits.front() == '_' || digits.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t process = 0;
    for (const auto character : digits) {
      if (character == '_') {
        continue;
      }

      if (character < '0' || character > '9') {
        return std::nullopt;
      }

      const auto digit = static_cast<std::uint32_t>(character - '0');
      if (process > (std::numeric_limits<std::uint32_t>::max() - digit) / 10) {
        return std::nullopt;
      }

      process = process * 10 + digit;
    }

    if (process == 0) {
      return std::nullopt;
    }

    const auto dot = name.substr(0, dash).rfind('.');
    if (dot == std::string_view::npos) {
      return std::nullopt;
    }

    const auto role = name.substr(dot + 1, dash - dot - 1);
    if (role != "runtime" && role != "client") {
      return std::nullopt;
    }

    return LogName{name.substr(0, dot), role == "runtime" ? Role::runtime : Role::client, process, rotated};
  }
};

}
