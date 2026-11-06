#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include "../graphics/child_file.hpp"
#include "../graphics/temporary_path.hpp"
#include "../graphics/kitty_framing.hpp"
#include <algorithm>
#include <charconv>
#include "../diagnostics/line.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
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



import telar.runtime.graphics.pane_media;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> responseBytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

static void testSharedTerminalResponses() {
  SystemAllocator system;
  BudgetAllocator memory{system, 16 * 1024 * 1024};
  const auto queue = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, decltype(memory)>{memory});
  Terminal terminal{memory, TerminalSize{80, 24, 0, 0}, TerminalPurpose::separate_media, queue};
  MediaTerminal media{memory, TerminalSize{80, 24, 0, 0}, GraphicsLimits{}, queue};
  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    media.reply(responseBytes("graphics reply"));
  }

  terminal.feed(responseBytes("\x1b[6n"));
  check(queue->snapshot().dropped == 0 && queue->snapshot().messages == PtyResponseQueue::message_capacity);
  check(std::ranges::equal(terminal.responses(), responseBytes("graphics reply")));
  terminal.consumeResponses(terminal.responses().size());
  terminal.feed(responseBytes("\x1b[6n"));
  for (std::size_t index = 1; index < PtyResponseQueue::message_capacity; ++index) {
    check(std::ranges::equal(media.responses(), responseBytes("graphics reply")));
    terminal.consumeResponses(media.responses().size());
  }
  check(std::ranges::equal(media.responses(), responseBytes("\x1b[1;1R")));
  terminal.consumeResponses(media.responses().size());
  check(std::ranges::equal(terminal.responses(), responseBytes("\x1b[1;1R")));
  terminal.consumeResponses(terminal.responses().size());

  bool rejected = false;
  try {
    media.reply(responseBytes(std::string(PtyResponseQueue::message_byte_capacity + 1, 'x')));
  } catch (const std::length_error &) {
    rejected = true;
  }
  check(rejected && queue->empty() && queue->snapshot().dropped == 0);
  terminal.feed(responseBytes("still usable"));
  terminal.refresh();
  check(terminal.screen.cells.front().text.front() == 's');
}

void testPtyResponses() {
  testPtyResponseQueue();
  testSharedTerminalResponses();
}
