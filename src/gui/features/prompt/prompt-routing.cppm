export module telar.gui.features.prompt:routing;

import std;

import telar.wire.pane_io;
import telar.base.ds;

// Who gets the keyboard of a pane in telar's prompt mode, from what the runtime reports about
// its shell. Anything uncertain falls back to the terminal as it is today: telar's editor only
// takes keys when the integrated shell is provably reading a command.
export namespace telar::gui::features::prompt {

  enum class Surface : std::uint8_t {
    // The terminal as usual: classic mode, no integrated shell, or a full-screen or raw program.
    none,
    // The shell waits for a command: telar's editor takes the keys.
    editor,
    // A program runs in the line discipline: keys queue the next command.
    running,
    // A program reads with echo off, as a password prompt does: keys go to it, shown as dots.
    secret,
  };

  Surface surface(const PaneShell& shell, bool alternate_screen, bool telar_mode) noexcept;

  // A key the line discipline turns into a signal or an end of file always reaches the program,
  // whatever the queue holds: the control characters come from the terminal's own settings.
  bool controlKey(const PaneShell& shell, std::string_view bytes) noexcept;

  // `text` as the one line a program reads: without the line ends a copied line brings at its
  // end. None when lines follow, which the program would read as more answers, or the shell as
  // commands once the program exits.
  ds::Option<std::string_view> oneLine(std::string_view text) noexcept;

  // A program that printed a line without ending it and then went quiet is most likely asking
  // for input (`rm -i`, `[Y/n]`), so typed keys go to it instead of the queue.
  struct PendingPrompt {
    static constexpr std::chrono::milliseconds quiet{300};

    static bool likely(std::uint32_t cursor_column, std::chrono::nanoseconds since_output) noexcept;
  };

}
