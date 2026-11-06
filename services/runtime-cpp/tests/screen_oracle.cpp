#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../diagnostics/line.hpp"
#include "telar_platform/trace.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include "telar_base/text/utf8.hpp"



import telar.runtime.agents.screen_inference;

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
