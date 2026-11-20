import std;
import telar.config.core;
import telar.runtime.terminal.graphics.file_input;
import telar.runtime.terminal.graphics.pane_media;
import telar.runtime.terminal.kitty;
import telar.vocabulary;
import telar.testing;
import telar.testing.test_memory;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr TerminalSize size{80, 24, 9, 18};

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  // Runs one batch on the caller's thread, as the media worker would.
  bool runBatch(PaneMedia& media) {
    check(media.seal());
    const bool reset = media.process();

    media.complete();
    return reset;
  }

  // In the product's ordered mode the media terminal sees every byte the interactive one
  // does: output past what a batch holds fails the pane instead of being dropped, and the
  // pane processes none of it.
  void orderedInputNeverDrops() {
    telar::testing::TestMemory adapter;
    MediaBudget budget{GraphicsLimits::maximum_global_bytes};
    PaneMedia media{adapter, budget, GraphicsLimits{}, size};
    const std::string filler(MediaBatch::byte_capacity, 'x');

    media.requireOrderedInput();
    media.output(bytes("\x1b_Ga=T,f=32,s=1,v=1,i=1,q=2;/wAA/w==\x1b\\"));
    check(!runBatch(media) && !media.failed());
    media.output(bytes(filler + "\x1b_Ga=T,f=32,s=1,v=1,i=2,q=2;/wAA/w==\x1b\\"));
    check(media.failed());
    check(media.takeDroppedBytes() == 0);

    // The failed pane runs no further batch and lets its media terminal go.
    check(!media.seal());
    check(media.terminal() == nullptr);
  }

  const telar::testing::Case case_ordered_input_never_drops{"pane_media.ordered_input_never_drops", orderedInputNeverDrops};

}
