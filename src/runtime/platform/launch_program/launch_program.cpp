module telar.runtime.platform.launch_program;

import telar.platform.process;

namespace telar::runtime {

  std::string_view launchedProgram(std::span<const std::string_view> arguments) noexcept {
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
