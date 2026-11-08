#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include "telar_base/diagnostics/config.hpp"
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
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
