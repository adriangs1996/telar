module telar.gui.features.prompt;

import std;

import telar.wire.pane_io;
import telar.wire.vocabulary;

namespace telar::gui::features::prompt {

  Surface surface(const PaneShell& shell, bool alternate_screen, bool telar_mode) noexcept {
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

  bool controlKey(const PaneShell& shell, std::string_view bytes) noexcept {
    if (bytes.size() != 1 || bytes.front() == 0) {
      return false;
    }

    const auto byte = static_cast<Byte>(bytes.front());
    if (shell.signal_keys && (byte == shell.interrupt || byte == shell.quit || byte == shell.suspend)) {
      return true;
    }

    return shell.canonical && byte == shell.end_of_file;
  }

  bool PendingPrompt::likely(std::uint32_t cursor_column, std::chrono::nanoseconds since_output) noexcept {
    return cursor_column != 0 && since_output >= quiet;
  }

}
