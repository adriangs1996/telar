export module telar.runtime.host.launch_program;

import std;

// Interface: platform/launch_program.cppm
export {
  namespace telar::runtime {

    std::string_view launchedProgram(std::span<const std::string_view> arguments) noexcept;

  }
}
