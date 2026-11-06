#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <algorithm>
#include <chrono>
#include <optional>
#include <cstddef>
#include <cstring>
#include <array>
#include <cstdint>
#include <span>
#include <string_view>
#include "../diagnostics/line.hpp"
#include "telar_platform/trace.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
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
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <atomic>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>



import telar.runtime.terminal.osc_scanner;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> bytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

static void testInputScanning() {
  constexpr std::string_view paste = "\x1b[200~line one\nline two\r\x03\x1b[201~";
  for (std::size_t split = 0; split <= paste.size(); ++split) {
    InputScanner scanner;
    const auto first = scanner.feed(bytes(paste.substr(0, split)));
    const auto second = scanner.feed(bytes(paste.substr(split)));
    check(!first.submitted && !second.submitted && !first.cancelled && !second.cancelled);
    check(scanner.feed(bytes("\r")).submitted);
    check(!scanner.typedText());
  }

  InputScanner scanner;
  scanner.feed(bytes("hello\x7f!"));
  check(scanner.typedText() == "hell!");
  check(scanner.feed(bytes("\x03")).cancelled);
  scanner.reset();
  check(scanner.typedText() == "");
  scanner.feed(bytes("café"));
  check(!scanner.typedText());

  OscScanner osc;
  std::string payload;
  unsigned starts = 0;
  unsigned finishes = 0;
  for (const auto byte : bytes("\x9dignored\x9c\x1b]133;B\x07\x1b]133;D;0\x1b\\")) {
    switch (osc.next(byte)) {
    case OscScanner::Event::start:
      ++starts;
      break;
    case OscScanner::Event::payload:
      payload += static_cast<char>(byte);
      break;
    case OscScanner::Event::end:
      ++finishes;
      break;
    case OscScanner::Event::none:
      break;
    }
  }
  check(starts == 2 && finishes == 2 && payload == "133;B133;D;0");
}

void testText() {
  testInputScanning();
  SystemAllocator system;
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  Terminal terminal{memory, TerminalSize{.cols = 20,
                                         .rows = 4,
                                         .cell_width_px = 0,
                                         .cell_height_px = 0}};
  check(terminal.outputSettled());
  terminal.feed(bytes("\x1b["));
  check(!terminal.outputSettled());
  terminal.feed(bytes("?2026h"));
  check(!terminal.outputSettled());
  terminal.feed(bytes("\x1b[?2026l\x1b]0;partial title"));
  check(!terminal.outputSettled());
  terminal.feed(bytes("\x07"));
  check(terminal.outputSettled());
  terminal.feed(bytes("first\r\nsecond\r\nthird\r\nfourth\r\nfifth"));
  TextReader screen{memory, terminal, 1024};
  screen.read(PaneTextSource::screen, 10);
  check(screen.text() == "second\nthird\nfourth\nfifth");
  TextReader recent{memory, terminal, 1024};
  recent.read(PaneTextSource::recent, 2);
  check(recent.text() == "fourth\nfifth");

  TextReader selection{memory, terminal, 1024};
  selection.copy(CopySelection{.start_x = 1,
                               .start_y = 0,
                               .end_x = 2,
                               .end_y = 1});
  check(selection.text() == "irst\nsec");

  TextSearch search{SearchPane{.request_id = 1,
                               .pane_id = 1,
                               .needle = "TH"},
                    terminal.contentRevision()};
  check(search.advance(terminal.handle(), terminal.contentRevision()));
  check(search.result().matches.empty());

  TextSearch folded{SearchPane{.request_id = 2,
                               .pane_id = 1,
                               .needle = "th"},
                    terminal.contentRevision()};
  check(folded.advance(terminal.handle(), terminal.contentRevision()));
  const auto matches = folded.result().matches;
  check(matches.size() == 3);
  check(matches[0].x == 0 && matches[0].y == 2);
  check(matches[1].x == 4 && matches[1].y == 3);

  TextSearch invalidated{SearchPane{.request_id = 3,
                                    .pane_id = 1,
                                    .needle = "x"},
                         terminal.contentRevision()};
  terminal.feed(bytes("x"));
  bool rejected = false;
  try {
    invalidated.advance(terminal.handle(), terminal.contentRevision());
  } catch (const EncodingError &) {
    rejected = true;
  }
  check(rejected);

  FramePacer pacer;
  const auto start = FramePacer::Time{std::chrono::seconds{1}};
  const auto interval = std::chrono::milliseconds{10};
  pacer.configure(interval);
  for (unsigned index = 0; index < 4; ++index) {
    check(!pacer.deadline(start));
    pacer.record(start, std::nullopt);
  }

  check(pacer.deadline(start) == start + interval);
  pacer.noteInput(start);
  for (unsigned index = 0; index < 16; ++index) {
    check(!pacer.deadline(start));
    pacer.record(start, std::nullopt);
  }
  check(pacer.deadline(start) == start + interval);
  check(!pacer.deadline(start + interval));
}
