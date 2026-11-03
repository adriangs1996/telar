#pragma once

#include "../machine_ssh.hpp"

namespace telar::runtime::cli::machine {

template <Allocator Memory>
launch::Output runScript(Memory &memory, std::string_view destination, std::string_view script, std::chrono::seconds timeout = probe_timeout) {
  return launch::captureBytes(ssh(memory, destination, "exec /bin/sh -s"), script, timeout);
}

inline std::string assign(std::string_view name, std::string_view value) {
  return std::string{name} + "=" + launch::quote(value) + "\n";
}

inline std::string whole(const launch::Output &output) {
  if (output.dropped != 0) {
    throw CommandError{"RemoteOutputTooLong"};
  }

  return output.out;
}

inline bool answeredYes() {
  std::string answer;
  if (!std::getline(std::cin, answer) || answer.size() > 16) {
    return false;
  }

  const auto text = config_receive::lower(trimmed(answer));
  return text == "y" || text == "yes";
}

}
