#pragma once

#include "../traffic/capture.hpp"

namespace telar::runtime::cli {

template <Allocator Memory>
void runTraffic(Memory &memory, std::span<char *const> arguments) {
  if (arguments.size() == 1 && std::string_view{arguments[0]} == "--help") {
    std::puts("Usage: telar-runtime traffic capture --socket RUNTIME_SOCKET\n       telar-runtime traffic import --socket RUNTIME_SOCKET --file CAPTURE.pcap\n\nEnable runtime.proxy.network_capture in the C++ runtime configuration.\nThe capture command needs root and observes active physical, loopback and virtual interfaces.\nImport is unprivileged and labels every event as offline. Neither command changes routes or trust.");
    return;
  }
  if (arguments.empty()) {
    throw std::invalid_argument{"Expected traffic capture|import; use traffic --help"};
  }

  const std::string_view action{arguments.front()};
  const char *socket = nullptr;
  const char *file = nullptr;
  for (std::size_t index = 1; index < arguments.size(); index += 2) {
    if (index + 1 == arguments.size()) {
      throw std::invalid_argument{"Missing traffic option value"};
    }
    const std::string_view option{arguments[index]};
    if (option == "--socket" && socket == nullptr) {
      socket = arguments[index + 1];
    } else if (option == "--file" && file == nullptr) {
      file = arguments[index + 1];
    } else {
      throw std::invalid_argument{"Unknown or duplicate traffic option"};
    }
  }
  if (socket == nullptr || (action != "capture" && action != "import") || ((action == "import") != (file != nullptr))) {
    throw std::invalid_argument{"Expected traffic capture --socket PATH or traffic import --socket PATH --file PCAP"};
  }

  String<Memory> path{socket, AllocatorRef<char, Memory>{memory}};
  path += traffic::socket_suffix;
  traffic::Capture capture{memory, traffic::connect(path)};
  if (file != nullptr) {
    capture.offline(file);
  } else {
    capture.live();
  }
}

}
