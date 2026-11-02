#include "core/memory.hpp"
#include "machines/connection_policy.hpp"
#include "probe_io.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "transport/runtime_handshake.hpp"
#include "transport/runtime_link.hpp"
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::probe;
constexpr std::size_t maximum_input = 65536;

void sample(SystemAllocator &memory) {
  const auto size = read<std::uint32_t>();
  if (size > maximum_input) {
    throw std::length_error{"HandshakeProbeInputTooLong"};
  }

  Vector<Byte, SystemAllocator> payload{AllocatorRef<Byte, SystemAllocator>{memory}};
  payload.resize(size);
  if (size != 0 && std::fread(payload.data(), 1, size, stdin) != size) {
    throw std::runtime_error{"TruncatedHandshakeProbeRequest"};
  }

  const auto result = RuntimeHandshake::inspect(payload);
  RuntimeLink bounded;
  bounded.fail(result.detail.view());
  const auto detail = bounded.failure().value_or(std::string_view{});
  write(static_cast<std::uint8_t>(!result.error));
  write(static_cast<std::uint8_t>(result.error && MachineConnectionPolicy::permanent(*result.error)));
  write(static_cast<std::uint32_t>(detail.size()));
  if (!detail.empty() && std::fwrite(detail.data(), 1, detail.size(), stdout) != detail.size()) {
    throw std::runtime_error{"HandshakeProbeWriteFailed"};
  }
}

}

int main() {
  try {
    SystemAllocator memory;
    while (std::getchar() != EOF) {
      sample(memory);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
