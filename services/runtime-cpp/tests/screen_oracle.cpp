#include "agents/screen_observation.hpp"

namespace {

struct Input {
  const telar::Byte *bytes;
  std::size_t length;
  std::uint16_t columns;
  std::uint16_t rows;
  std::uint16_t chunk;
  std::uint8_t provider;
  std::uint8_t manifests;
};

}

extern "C" std::uint32_t scan_screen(const Input *input) {
  using namespace telar;
  using namespace telar::runtime;
  try {
    SystemAllocator memory;
    Terminal terminal{memory, TerminalSize{input->columns, input->rows, 0, 0}, TerminalPurpose::observation};
    auto remaining = std::span{input->bytes, input->length};
    while (!remaining.empty()) {
      const auto count = input->chunk == 0 ? remaining.size() : std::min<std::size_t>(input->chunk, remaining.size());
      terminal.feed(remaining.first(count));
      remaining = remaining.subspan(count);
    }

    terminal.refresh();
    const AgentManifests empty_manifests;
    const AgentScreenReader reader{terminal, input->manifests == 0 ? empty_manifests : builtin_manifests};
    const auto provider = static_cast<AgentProvider>(input->provider);
    const auto signal = reader.signal(provider);
    std::uint32_t result = static_cast<std::uint32_t>(reader.observe(provider).restored_draft) << 6;
    if (signal) {
      switch (signal->status) {
      case AgentStatus::working:
        result |= 1;
        break;
      case AgentStatus::blocked:
        result |= 2;
        break;
      case AgentStatus::ready:
        result |= 3;
        break;
      default:
        return 0x80000000;
      }
      result |= static_cast<std::uint32_t>(signal->identity_confirmed) << 4;
      result |= static_cast<std::uint32_t>(signal->ready_confirmed) << 5;
      result |= static_cast<std::uint32_t>(signal->confidence) << 8;
    }

    return result;
  } catch (...) {
    return 0x80000000;
  }
}
