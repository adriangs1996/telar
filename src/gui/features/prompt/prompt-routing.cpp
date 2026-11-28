module telar.gui.features.prompt;

import std;

import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::prompt {

  namespace {

    // A letter of a word a question offers: ASCII's, or a byte of a character past it (`sí`),
    // without the C library's locale, which reads those bytes as Latin-1.
    constexpr bool letter(char byte) noexcept {
      constexpr unsigned char first_non_ascii = 0x80;
      const auto value = static_cast<unsigned char>(byte);

      return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || value >= first_non_ascii;
    }

  }

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

  ds::Option<std::string_view> oneLine(std::string_view text) noexcept {
    const auto end = text.find_last_not_of("\r\n");
    const auto line = end == std::string_view::npos ? std::string_view{} : std::string_view{text.data(), end + 1};
    if (line.find_first_of("\r\n") != std::string_view::npos) {
      return ds::none;
    }

    return line;
  }

  bool PendingPrompt::question(std::string_view asked) noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    // The longest choice of words read inside brackets: `[y/n/a/q/d]`, `(yes/no/all)`.
    constexpr std::size_t longest_choice = 24;

    const auto end = asked.find_last_not_of(" \t");
    if (end == std::string_view::npos) {
      return false;
    }

    const auto text = asked.substr(0, end + 1);
    const char last = text.back();

    // The full-width marks a CJK question ends in, as the ASCII ones.
    if (last == '?' || last == ':' || text.ends_with("\uff1f") || text.ends_with("\uff1a")) {
      return true;
    }

    if (last == '>') {
      const char before = text.size() < 2 ? ' ' : text[text.size() - 2];

      return before == '>' || before == ' ' || before == ')' || letter(before) || (before >= '0' && before <= '9');
    }

    if (last != ']' && last != ')') {
      return false;
    }

    const auto open = text.find_last_of(last == ']' ? '[' : '(');
    if (open == std::string_view::npos || text.size() - open - 2 > longest_choice) {
      return false;
    }

    const auto choice = text.substr(open + 1, text.size() - open - 2);
    const bool words = std::ranges::all_of(choice, [](char byte) {
      return byte == '/' || letter(byte);
    });

    return words && choice.contains('/') && !choice.starts_with('/') && !choice.ends_with('/');
  }

  bool PendingPrompt::likely(std::string_view asked, std::chrono::nanoseconds since_output) noexcept {
    return since_output >= quiet && question(asked);
  }

}
