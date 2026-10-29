#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <string_view>

namespace telar::gui::platform {

struct CommandLine {
  static constexpr std::size_t maximum_arguments = 5;

  std::string_view executable;
  std::array<std::string_view, maximum_arguments> values{};
  std::size_t count = 0;

  template <std::size_t Count>
  [[nodiscard]] static constexpr CommandLine withArguments(std::string_view executable, const std::array<std::string_view, Count> &arguments) noexcept {
    static_assert(Count <= maximum_arguments);
    CommandLine command{.executable = executable, .count = Count};
    std::copy(arguments.begin(), arguments.end(), command.values.begin());

    return command;
  }

  [[nodiscard]] std::span<const std::string_view> arguments() const noexcept {
    return std::span{values}.first(count);
  }
};

}
