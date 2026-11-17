import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.runtime.agents.screen_inference;
import telar.runtime.terminal.text_reader;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void feed(Terminal& terminal, std::string_view text) {
    terminal.feed({reinterpret_cast<const Byte*>(text.data()), text.size()});
    terminal.refresh();
  }

  void testCursorStatus() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{80, 24, 8, 16}};

    // Cursor's composer while a turn runs, with no spinner on screen.
    feed(terminal, "\x1b[2J\x1b[22;1H→ Add a follow-up   ctrl+c to stop");
    check(AgentScreenReader{terminal}.observe(AgentProvider::cursor).status == AgentStatus::working, "a running cursor turn reads as ready");

    // A permission question above the composer waits on the user, whatever the composer shows.
    feed(terminal, "\x1b[2J\x1b[10;1HNot in allowlist: rm -rf build\x1b[22;1H→ Add a follow-up");
    AgentScreenInference inference;
    const auto signal = inference.observe(terminal, builtin_manifests, AgentProvider::cursor, {1000, 1'000'000'000});

    check(signal && signal->status == AgentStatus::blocked, "a blocked cursor agent reads as ready");
  }

  const telar::testing::Case case_cursor_status{"screen_inference.cursor_status", testCursorStatus};

}
