#include "check.hpp"
#include "graphics/media_terminal.hpp"
#include "terminal/terminal.hpp"

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
  check(queue->snapshot().dropped == 1 && queue->snapshot().messages == PtyResponseQueue::message_capacity);
  check(std::ranges::equal(terminal.responses(), responseBytes("graphics reply")));
  terminal.consumeResponses(terminal.responses().size());
  terminal.feed(responseBytes("\x1b[6n"));
  for (std::size_t index = 1; index < PtyResponseQueue::message_capacity; ++index) {
    check(std::ranges::equal(media.responses(), responseBytes("graphics reply")));
    media.consumeResponses(media.responses().size());
  }
  check(std::ranges::equal(media.responses(), responseBytes("\x1b[1;1R")));
  media.consumeResponses(media.responses().size());

  media.reply(responseBytes(std::string(PtyResponseQueue::message_byte_capacity + 1, 'x')));
  check(queue->empty() && queue->snapshot().dropped == 2);
  terminal.feed(responseBytes("still usable"));
  terminal.refresh();
  check(terminal.screen.cells.front().text.front() == 's');
}

void testPtyResponses() {
  testPtyResponseQueue();
  testSharedTerminalResponses();
}
