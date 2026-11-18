#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.testing;
import telar.runtime.terminal.osc_scanner;
import telar.runtime.terminal.text_reader;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  void testInputScanning() {
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
    SystemAllocator system;
    BudgetAllocator budget{system, 32 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{.cols = 20, .rows = 4, .cell_width_px = 0, .cell_height_px = 0}};

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

    selection.copy(CopySelection{.start_x = 1, .start_y = 0, .end_x = 2, .end_y = 1});
    check(selection.text() == "irst\nsec");

    TextSearch search{SearchPane{.request_id = 1, .pane_id = 1, .needle = "TH"}, terminal.contentRevision()};

    check(search.advance(terminal.handle(), terminal.contentRevision()));
    check(search.result().matches.empty());

    TextSearch folded{SearchPane{.request_id = 2, .pane_id = 1, .needle = "th"}, terminal.contentRevision()};

    check(folded.advance(terminal.handle(), terminal.contentRevision()));
    const auto matches = folded.result().matches;

    check(matches.size() == 3);
    check(matches[0].x == 0 && matches[0].y == 2);
    check(matches[1].x == 4 && matches[1].y == 3);

    TextSearch invalidated{SearchPane{.request_id = 3, .pane_id = 1, .needle = "x"}, terminal.contentRevision()};

    terminal.feed(bytes("x"));
    bool rejected = false;

    try {
      invalidated.advance(terminal.handle(), terminal.contentRevision());
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected);

    FramePacer pacer;
    const auto start = FramePacer::Time{std::chrono::seconds{1}};
    const auto interval = std::chrono::milliseconds{10};

    pacer.configure(interval);
    for (unsigned index = 0; index < 4; ++index) {
      check(!pacer.deadline(start));
      pacer.record(start, ds::none);
    }

    check(pacer.deadline(start) == start + interval);
    pacer.noteInput(start);
    for (unsigned index = 0; index < 16; ++index) {
      check(!pacer.deadline(start));
      pacer.record(start, ds::none);
    }

    check(pacer.deadline(start) == start + interval);
    check(!pacer.deadline(start + interval));
  }

  // A reader smaller than the text keeps its end, the part a user saw last, cut at a line
  // start, or at a character start when the end is one long line.
  void testTruncatedTail() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;

    {
      Terminal terminal{memory, TerminalSize{.cols = 20, .rows = 4, .cell_width_px = 0, .cell_height_px = 0}};

      terminal.feed(bytes("first\r\nsecond\r\nthird\r\nfourth\r\nfifth"));
      TextReader reader{memory, terminal, 10};

      reader.read(PaneTextSource::screen, 10);
      check(reader.truncated());
      check(reader.text() == "fifth");
    }

    Terminal terminal{memory, TerminalSize{.cols = 20, .rows = 4, .cell_width_px = 0, .cell_height_px = 0}};

    terminal.feed(bytes("\xe7\x95\x8c\xe7\x95\x8c\xe7\x95\x8c\xe7\x95\x8c\xe7\x95\x8c\xe7\x95\x8c"));
    TextReader reader{memory, terminal, 10};

    reader.read(PaneTextSource::screen, 10);
    check(reader.truncated());
    check(reader.text() == "\xe7\x95\x8c\xe7\x95\x8c\xe7\x95\x8c");
  }

  std::vector<PaneMatch> search(Terminal& terminal, const auto& request, bool* truncated = nullptr) {
    TextSearch search{request, terminal.contentRevision()};

    while (!search.advance(terminal.handle(), terminal.contentRevision())) {
    }

    const auto result = search.result();

    if (truncated != nullptr) {
      *truncated = result.truncated;
    }

    return {result.matches.begin(), result.matches.end()};
  }

  // Search finds a needle that starts inside a partial match, needles with characters past
  // ASCII on wide cells, only the rows a client asks for, and says when it kept fewer
  // matches than there are.
  void testSearchOverlapUnicodeRanges() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{.cols = 20, .rows = 6, .cell_width_px = 0, .cell_height_px = 0}};

    terminal.feed(bytes("aaab\r\ncaf\xc3\xa9\r\na\xe7\x95\x8c"
                        "b\r\nthe\r\nthe\r\nthe"));
    const auto overlap = search(terminal, SearchPane{.request_id = 1, .pane_id = 1, .needle = "aab"});

    check(overlap.size() == 1 && overlap[0].x == 1 && overlap[0].y == 0 && overlap[0].len == 3);
    const auto accented = search(terminal, SearchPane{.request_id = 2, .pane_id = 1, .needle = "\xc3\xa9"});

    check(accented.size() == 1 && accented[0].x == 3 && accented[0].y == 1 && accented[0].len == 1);
    const auto wide = search(terminal, SearchPane{.request_id = 3, .pane_id = 1, .needle = "\xe7\x95\x8c"
                                                                                           "b"});

    check(wide.size() == 1 && wide[0].x == 1 && wide[0].y == 2 && wide[0].len == 3);
    const auto ranged = search(terminal, SearchPaneRows{.request_id = 4, .pane_id = 1, .needle = "the", .first_row = 3, .last_row = 4});

    check(ranged.size() == 2 && ranged[0].y == 3 && ranged[1].y == 4);

    Terminal full{memory, TerminalSize{.cols = 20, .rows = 20, .cell_width_px = 0, .cell_height_px = 0}};

    full.feed(bytes(std::string(20 * 20, 'x')));
    bool truncated = false;
    const auto many = search(full, SearchPane{.request_id = 5, .pane_id = 1, .needle = "x"}, &truncated);

    check(truncated && many.size() == 256);
  }

  const telar::testing::Case case_text{"text.text", testText};
  const telar::testing::Case case_input_scanning{"text.input_scanning", testInputScanning};
  const telar::testing::Case case_truncated_tail{"text.truncated_tail_on_boundary", testTruncatedTail};
  const telar::testing::Case case_search_overlap_unicode_ranges{"text.search_overlap_unicode_ranges", testSearchOverlapUnicodeRanges};

}
