#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "protocol_peer.hpp"
#include <string_view>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>
#include <exception>
#include <cstddef>
#include "telar_base/program_identity.hpp"
#include <cerrno>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <optional>
#include <sys/types.h>
#include <limits.h>
#include <atomic>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>
#include <thread>

#pragma once



import telar.config;
import telar.platform;

namespace hook_fixture {

inline void require(bool valid, const char *message) {
  if (!valid) {
    throw std::runtime_error{message};
  }
}

inline std::string runHook(std::string_view provider, std::string_view input, bool merge_errors = false) {
  using namespace telar;
  using namespace telar::runtime;
  const char *binary = std::getenv("TELAR_BIN_PATH");
  require(binary != nullptr, "Pane did not receive its runtime executable");
  SystemAllocator memory;
  const std::array<std::string_view, 3> arguments{binary, "hook", provider};
  const std::array<std::string_view, 7> diagnostic_arguments{"/bin/sh", "-c", "exec \"$@\" 2>&1", "hook-fixture", binary, "hook", provider};
  const std::span<const std::string_view> selected = merge_errors ? std::span<const std::string_view>{diagnostic_arguments} : std::span<const std::string_view>{arguments};
  Command command{memory, telar::Launch{.arguments = selected}, CommandPurpose::configured_helper};
  CommandOutput output{memory, 4096};
  const std::array parts{input};
  if (output.runWithInput(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}, parts) != 0) {
    throw std::runtime_error{std::string{"Hook command failed: "} + std::string{output.text()}};
  }
  return std::string{output.text()};
}

inline void waitProvider(ProtocolPeer &peer, telar::AgentProvider provider) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    const auto snapshot = peer.exchange<telar::AgentSnapshot>(telar::QueryAgents{1});
    if (snapshot.entries.size() == 1 && snapshot.entries[0].provider == provider) {
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  } while (std::chrono::steady_clock::now() < deadline);

  throw std::runtime_error{"Hook fixture provider was not identified"};
}

}
