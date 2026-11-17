// What a key, the pointer or a search asks of copy mode: the state it leads to and what the
// session sends, and how the search stands.
export module telar.gui.features.terminal.copy_mode:plan;

import std;

import :state;
import telar.gui.foundation.terminal;
import telar.wire.clipboard;
import telar.wire.pane_io;
import telar.wire.vocabulary;

// Interface: terminal/copy_navigation.cppm
export {
  namespace telar::gui::features::terminal::copy_mode {

    struct CopyEffect {
      bool handled = true;
      bool exit = false;
      bool copy = false;
      std::optional<CopyDirection> search = std::nullopt;
      bool open_link = false;
    };

  }
}

// Interface: terminal/copy_mode.cppm
export {
  namespace telar::gui::features::terminal::copy_mode {

    struct CopyPlan {
      std::uint64_t revision = 0;
      std::optional<CopyState> next = std::nullopt;
      CopyEffect effect{};
      std::optional<CopySelection> selection = std::nullopt;
      std::optional<SetPaneViewport> viewport = std::nullopt;
      std::optional<std::span<const PaneMatch>> replacement_matches = std::nullopt;
    };

    // The output a search begun from a command reads, and whether it reads only that.
    struct CopySearchRows {
      std::size_t block = 0;
      std::uint32_t first = 0;
      std::uint32_t last = 0;
    };

    // What the copy-mode search looks for, whether an answer is awaited, and how its matches
    // stand: how many, which the cursor is on, and whether there were more than it kept.
    struct CopySearchState {
      std::string_view query;
      bool searching = false;
      std::size_t count = 0;
      std::size_t index = 0;
      bool truncated = false;
    };

  }
}
