#pragma once

#include <span>
#include <string_view>

namespace telar::runtime {

inline std::string_view loginShellScript(std::string_view shell) noexcept {
  const auto name = shell.substr(shell.rfind('/') + 1);
  if (name == "bash" || name == "zsh" || name == "ksh") {
    return "exec -- \"$0\" \"$@\"";
  }

  if (name == "sh" || name == "dash") {
    return "exec \"$0\" \"$@\"";
  }

  return name == "fish" ? "exec $argv" : std::string_view{};
}

inline std::string_view launchedProgram(std::span<const std::string_view> arguments) noexcept {
  if (arguments.empty()) {
    return {};
  }

  constexpr std::size_t wrapped_program_index = 5;
  if (arguments.size() <= wrapped_program_index || arguments[1] != "-l" || arguments[2] != "-i" || arguments[3] != "-c") {
    return arguments.front();
  }

  const auto script = loginShellScript(arguments.front());
  return !script.empty() && arguments[4] == script ? arguments[wrapped_program_index] : arguments.front();
}

}
