#pragma once

#include <array>
#include <cstddef>
#include <span>
#include <string_view>

namespace telar::runtime::config {

struct CommandTabView {
  static constexpr std::size_t maximum_arguments = 32;
  static constexpr std::size_t maximum_argument_bytes = 4096;
  static constexpr std::size_t maximum_label_bytes = 32;

  std::array<std::string_view, maximum_arguments> arguments{};
  std::size_t count = 0;
  std::string_view configured_label;

  [[nodiscard]] std::span<const std::string_view> argv() const noexcept {
    return std::span{arguments}.first(count);
  }

  [[nodiscard]] std::string_view label() const noexcept {
    if (!configured_label.empty() || count == 0) {
      return configured_label;
    }

    auto executable = arguments.front();
    const auto last = executable.find_last_not_of('/');
    if (last == std::string_view::npos) {
      return {};
    }

    executable.remove_suffix(executable.size() - last - 1);
    const auto separator = executable.find_last_of('/');
    if (separator != std::string_view::npos) {
      executable.remove_prefix(separator + 1);
    }

    return executable;
  }
};

}
