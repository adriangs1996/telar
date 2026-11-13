module;
#include <cstddef>
#include <cstdint>

export module telar.gui.prompt.routing;

import std;

export import telar.client.protocol;

// Who gets the keyboard of a pane in telar's prompt mode, from what the runtime reports about
// its shell. Anything uncertain falls back to the terminal as it is today: telar's editor only
// takes keys when the integrated shell is provably reading a command.
export namespace telar::gui::prompt {

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

inline Surface surface(const PaneShell &shell, bool alternate_screen, bool telar_mode) noexcept {
  if (!telar_mode || shell.shell == IntegratedShell::none || alternate_screen) {
    return Surface::none;
  }

  switch (shell.phase) {
  case ShellPhase::prompt:
    // A remote shell's prompt is behind ssh, the local foreground program.
    return shell.shell_foreground || shell.remote ? Surface::editor : Surface::none;
  case ShellPhase::running:
    if (!shell.canonical) {
      return Surface::none;
    }
    return shell.echo ? Surface::running : Surface::secret;
  case ShellPhase::unknown:
    break;
  }
  return Surface::none;
}

// A key the line discipline turns into a signal or an end of file always reaches the program,
// whatever the queue holds: the control characters come from the terminal's own settings.
inline bool controlKey(const PaneShell &shell, std::string_view bytes) noexcept {
  if (bytes.size() != 1 || bytes.front() == 0) {
    return false;
  }

  const auto byte = static_cast<Byte>(bytes.front());
  if (shell.signal_keys && (byte == shell.interrupt || byte == shell.quit || byte == shell.suspend)) {
    return true;
  }
  return shell.canonical && byte == shell.end_of_file;
}

// A program that printed a line without ending it and then went quiet is most likely asking
// for input (`rm -i`, `[Y/n]`), so typed keys go to it instead of the queue.
struct PendingPrompt {
  static constexpr std::chrono::milliseconds quiet{300};

  inline static bool likely(std::uint32_t cursor_column, std::chrono::nanoseconds since_output) noexcept {
    return cursor_column != 0 && since_output >= quiet;
  }
};

}
