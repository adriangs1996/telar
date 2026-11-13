#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/diagnostics/config.hpp"
#include "cell_layout.hpp"
#include <cstring>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

void testFrameSync() {
  SystemAllocator system;
  BudgetAllocator memory{system, 16 * 1024 * 1024};
  Screen screen{memory};
  screen.resize(80, 24);
  screen.scroll.total_rows = 24;
  FrameSync sync{memory, 7};
  std::array<Byte, 128 * 1024> decoded{};
  DecodeStorage storage{decoded};

  auto payload = sync.prepare(screen);
  auto frame = Codec::decode<PaneFrame>(payload, storage);
  check(frame.frame_id == 1);
  check(frame.base_frame_id == 0);
  check(frame.spans.size() == 1);
  check(frame.spans[0].count == 80 * 24);
  check(!sync.acknowledge(0));
  check(!sync.acknowledge(2));
  check(sync.prepare(screen).empty());

  screen.cells[17].text[0] = 'X';
  screen.row_revisions[0] = ++screen.revision;
  check(sync.prepare(screen).empty());
  check(sync.acknowledge(1));
  check(!sync.acknowledge(1));
  storage = DecodeStorage{decoded};
  frame = Codec::decode<PaneFrame>(sync.prepare(screen), storage);
  check(frame.frame_id == 2);
  check(frame.base_frame_id == 1);
  check(frame.spans.size() == 1);
  check(frame.spans[0].start == 17);
  check(frame.spans[0].count == 1);
  check(frame.spans[0].reader().next()->text[0] == 'X');
  check(sync.acknowledge(2));

  const auto allocations = memory.allocations();
  ++screen.revision;
  check(sync.prepare(screen).empty());
  sync.requestSnapshot();
  storage = DecodeStorage{decoded};
  frame = Codec::decode<PaneFrame>(sync.prepare(screen), storage);
  check(frame.base_frame_id == 0);
  check(memory.allocations() == allocations);
  check(sync.acknowledge(frame.frame_id));
  for (const bool enabled : {true, false}) {
    screen.input_modes.paste_events = enabled;
    ++screen.revision;
    storage = DecodeStorage{decoded};
    frame = Codec::decode<PaneFrame>(sync.prepare(screen), storage);
    check(frame.input_modes.paste_events == enabled && frame.spans.empty());
    check(sync.acknowledge(frame.frame_id));
    check(sync.prepare(screen).empty());
  }
}
