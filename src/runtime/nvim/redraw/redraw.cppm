export module telar.runtime.nvim.redraw;

import std;
import telar.base.memory.allocators;
import telar.runtime.nvim.screen;

// Interface: nvim/redraw.cppm
export {
  namespace telar::runtime {

    struct NvimRedraw {
      // False for a notification that is not what Neovim's UI protocol says, or that asks the
      // screen for more than its limits: the editor that sent it is closed.
      bool accepted = true;
      // The flushes it held: the screen is ready to show after the last one.
      std::uint32_t flushes = 0;
      bool bell = false;
    };

    // Applies the events of one `redraw` notification, the bytes of its parameters, to the
    // screen. Events and parameters this build does not know are skipped, as the protocol asks
    // of a client.
    NvimRedraw applyRedraw(NvimScreen& screen, std::span<const std::uint8_t> notification, ConcurrentMemory& memory);

  }
}
