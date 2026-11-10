#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>
#include <cstdlib>

import std;
import telar.gui.prompt.editor;
import telar.gui.prompt.routing;
import telar.gui.prompt.layout;

using namespace telar::gui::prompt;

namespace {

const telar::gui::prompt::Editor *current = nullptr;

void require(bool condition, std::string_view message, std::source_location location = std::source_location::current()) {
  if (!condition) {
    if (current != nullptr) {
      const auto value = current->text().view();
      std::fprintf(stderr, "text: [%.*s] cursor %zu\n", static_cast<int>(value.size()), value.data(), current->text().cursor());
    }
    std::fprintf(stderr, "%s:%u: %.*s\n", location.file_name(), location.line(), static_cast<int>(message.size()), message.data());
    std::exit(1);
  }
}

// Types `keys` one by one: printable characters as themselves, `\x1b` as Escape and `\r` as
// Enter. Returns the last request.
Request type(Editor &editor, std::string_view keys) {
  current = &editor;
  Request last = Request::none;
  for (std::size_t index = 0; index < keys.size(); ++index) {
    const auto byte = keys[index];
    if (byte == '\x1b') {
      last = editor.press({Key::escape});
    } else if (byte == '\r') {
      last = editor.press({Key::enter});
    } else {
      last = editor.press({Key::character, static_cast<char32_t>(static_cast<unsigned char>(byte)), {}, keys.substr(index, 1)});
    }
  }
  return last;
}

Request control(Editor &editor, char key) {
  return editor.press({Key::character, static_cast<char32_t>(key), {.control = true}});
}

Request meta(Editor &editor, char key) {
  return editor.press({Key::character, static_cast<char32_t>(key), {.alt = true}});
}

std::string_view text(const Editor &editor) {
  return editor.text().view();
}

void textModel() {
  Text value;
  value.insert("git ", true);
  value.insert("status", true);
  require(value.view() == "git status", "typing appends");
  require(value.undo() && value.view().empty(), "one undo removes a run of typing");
  require(value.redo() && value.view() == "git status", "redo restores it");

  value.assign("café 🙂");
  value.moveTo(value.size());
  value.moveTo(value.previous(value.cursor()));
  require(value.view().substr(value.cursor()) == "🙂", "moves by code point");
  value.moveTo(4);
  require(value.cursor() == 3, "a cursor never splits a code point");

  value.assign("one\ntwo\nthree");
  require(value.lineCount() == 3 && value.lineOf(5) == 1, "counts lines");
  require(value.lineStart(5) == 4 && value.lineEnd(5) == 7, "finds line bounds");
  require(value.atColumn(8, 2) == 10, "keeps a column");

  const std::string huge(Text::capacity + 1, 'x');
  Text bounded;
  require(!bounded.replace(0, 0, huge) && bounded.empty(), "refuses text beyond the capacity");
}

void emacs() {
  Editor editor;
  type(editor, "git commit -m wip");
  require(text(editor) == "git commit -m wip", "types");
  control(editor, 'w');
  require(text(editor) == "git commit -m ", "Ctrl-W kills the word before the cursor");
  control(editor, 'y');
  require(text(editor) == "git commit -m wip", "Ctrl-Y yanks it back");
  control(editor, 'a');
  require(editor.text().cursor() == 0, "Ctrl-A goes to the line start");
  meta(editor, 'f');
  require(editor.text().cursor() == 3, "Alt-F moves past a word");
  control(editor, 'k');
  require(text(editor) == "git", "Ctrl-K kills to the end");
  control(editor, 'e');
  type(editor, "s");
  control(editor, 't');
  require(text(editor) == "gist", "Ctrl-T transposes");
  control(editor, 'u');
  require(text(editor).empty(), "Ctrl-U kills to the line start");
  require(control(editor, 'd') == Request::end_of_file, "Ctrl-D on an empty line is end of file");

  type(editor, "for f in *; do");
  require(editor.press({Key::enter}) == Request::submit, "Enter asks to submit");
  editor.newline();
  type(editor, "  echo $f");
  editor.press({Key::enter, 0, {.alt = true}});
  require(text(editor) == "for f in *; do\n  echo $f\n", "Alt-Enter inserts a newline");
  type(editor, "done");
  require(editor.press({Key::up}) == Request::none && editor.text().lineOf(editor.text().cursor()) == 1, "Up moves to the line above");
  editor.press({Key::up});
  require(editor.press({Key::up}) == Request::history_previous, "Up on the first line reaches the history");
  editor.press({Key::end});
  editor.press({Key::left, 0, {.shift = true}});
  editor.press({Key::left, 0, {.shift = true}});
  require(editor.text().selecting(), "Shift extends a selection");
  type(editor, "XX");
  require(text(editor).starts_with("for f in *; XX\n"), "typing replaces the selection");
  require(control(editor, 'c') == Request::cancel, "Ctrl-C cancels");
  require(editor.press({Key::tab}) == Request::complete, "Tab completes");
  require(control(editor, 'r') == Request::history_search, "Ctrl-R searches the history");
}

Editor vim(std::string_view initial) {
  Editor editor{Keymap::vim};
  type(editor, initial);
  type(editor, "\x1b");
  return editor;
}

void vimBasics() {
  auto editor = vim("git switch main");
  require(editor.mode() == Mode::normal && editor.text().cursor() == 14, "Escape enters normal mode on the last character");
  type(editor, "0");
  require(editor.text().cursor() == 0, "0 goes to the line start");
  type(editor, "w");
  require(editor.text().cursor() == 4, "w moves to the next word");
  type(editor, "e");
  require(editor.text().cursor() == 9, "e moves to the end of the word");
  type(editor, "b");
  require(editor.text().cursor() == 4, "b moves back to the word start");
  type(editor, "$");
  require(editor.text().cursor() == 14, "$ goes to the last character");
  type(editor, "^");
  require(editor.text().cursor() == 0, "^ goes to the first non-blank");
  type(editor, "fm");
  require(editor.text().cursor() == 11, "f finds a character");
  type(editor, "0tw");
  require(editor.text().cursor() == 4, "t stops before a character");
  type(editor, "0ti;");
  require(editor.text().cursor() == 5, "; repeats t past the character it stopped at");
  require(type(editor, "\r") == Request::submit, "Enter in normal mode submits");
  require(type(editor, "k") == Request::history_previous, "k on the first line reaches the history");
}

void vimOperators() {
  auto editor = vim("git switch main");
  type(editor, "0dw");
  require(text(editor) == "switch main", "dw deletes a word and its blanks");
  type(editor, "u");
  require(text(editor) == "git switch main", "u undoes");
  control(editor, 'r');
  require(text(editor) == "switch main", "Ctrl-R redoes");
  type(editor, "u0wcwrestore\x1b");
  require(text(editor) == "git restore main" && editor.mode() == Mode::normal, "cw changes to the word end");
  type(editor, "0w.");
  require(text(editor) == "git restore main", "a repeated cw on the same word keeps it");
  type(editor, "$ciwdev\x1b");
  require(text(editor) == "git restore dev", "ciw changes the word under the cursor");
  type(editor, "0x");
  require(text(editor) == "it restore dev", "x deletes a character");
  type(editor, "3x");
  require(text(editor) == "restore dev", "a count repeats x");
  type(editor, "P");
  require(text(editor) == "it restore dev", "P puts the deleted text before the cursor");
  type(editor, "0rX");
  require(text(editor) == "Xt restore dev", "r replaces a character");
  type(editor, "~");
  require(text(editor) == "xt restore dev", "~ toggles the case");
  type(editor, "D");
  require(text(editor) == "x", "D deletes to the line end");
}

void vimObjects() {
  auto editor = vim("echo \"hello world\" (a (b) c)");
  type(editor, "0fwci\"bye\x1b");
  require(text(editor) == "echo \"bye\" (a (b) c)", "ci\" changes inside quotes");
  type(editor, "fbda(");
  require(text(editor) == "echo \"bye\" (a  c)", "da( deletes the innermost parentheses");
  type(editor, "0fadi(");
  require(text(editor) == "echo \"bye\" ()", "di( empties the parentheses");
  type(editor, "0daw");
  require(text(editor) == "\"bye\" ()", "daw deletes a word with its blanks");
}

void vimLines() {
  Editor editor{Keymap::vim};
  type(editor, "one\ntwo\nthree");
  type(editor, "\x1bgg");
  require(editor.text().cursor() == 0, "gg goes to the first line");
  type(editor, "yyjp");
  require(text(editor) == "one\ntwo\none\nthree", "yy and p copy a line below");
  type(editor, "dd");
  require(text(editor) == "one\ntwo\nthree", "dd deletes the line");
  type(editor, "G");
  require(editor.text().lineOf(editor.text().cursor()) == 2, "G goes to the last line");
  type(editor, "ggJ");
  require(text(editor) == "one two\nthree", "J joins lines");
  type(editor, "ofour\x1b");
  require(text(editor) == "one two\nfour\nthree", "o opens a line below");
  type(editor, "2dd");
  require(text(editor) == "one two", "2dd deletes two lines");
  type(editor, "\"ayy\"ap");
  require(text(editor) == "one two\none two", "named registers keep their text");
  type(editor, ">>");
  require(text(editor) == "one two\n  one two", ">> indents the line");
}

void vimVisual() {
  auto editor = vim("git log --oneline");
  type(editor, "0wviwd");
  require(text(editor) == "git  --oneline", "v with a text object selects and deletes");
  type(editor, "0vey$p");
  require(text(editor) == "git  --onelinegit", "visual y yanks the selection");
  std::string clipboard;
  editor.setClipboard({.read = [&] { return std::string{"pasted"}; }, .write = [&](std::string_view text) { clipboard.assign(text); }});
  type(editor, "0\"+yiw");
  require(clipboard == "git", "the + register writes the system clipboard");
  type(editor, "$\"+p");
  require(text(editor).ends_with("pasted"), "the + register reads it");
}

void routing() {
  telar::PaneShell shell{.pane_id = 1, .shell = telar::IntegratedShell::zsh, .phase = telar::ShellPhase::prompt, .shell_foreground = true, .canonical = false, .echo = false, .signal_keys = false, .interrupt = 3, .quit = 28, .suspend = 26, .end_of_file = 4};
  require(surface(shell, false, true) == Surface::editor, "the editor takes a shell at its prompt");
  require(surface(shell, false, false) == Surface::none, "classic mode leaves the terminal alone");
  require(surface(shell, true, true) == Surface::none, "the alternate screen belongs to its program");
  shell.shell_foreground = false;
  require(surface(shell, false, true) == Surface::none, "a prompt without the terminal is not trusted");
  shell.remote = true;
  require(surface(shell, false, true) == Surface::editor, "a remote shell's prompt is behind ssh, which holds the terminal");
  shell.remote = false;

  shell.phase = telar::ShellPhase::running;
  shell.canonical = shell.echo = shell.signal_keys = true;
  require(surface(shell, false, true) == Surface::running, "a program in the line discipline queues keys");
  shell.echo = false;
  require(surface(shell, false, true) == Surface::secret, "echo off in canonical mode is a secret");
  shell.canonical = false;
  require(surface(shell, false, true) == Surface::none, "a raw program gets the keyboard");

  shell.canonical = true;
  require(controlKey(shell, "\x03") && controlKey(shell, "\x1c") && controlKey(shell, "\x1a"), "signal keys reach the program");
  require(controlKey(shell, "\x04") && !controlKey(shell, "a") && !controlKey(shell, "\x03\x03"), "end of file reaches it, typing does not");
  shell.signal_keys = false;
  require(!controlKey(shell, "\x03"), "without ISIG Ctrl-C is a character");
  shell.shell = telar::IntegratedShell::none;
  shell.phase = telar::ShellPhase::unknown;
  require(surface(shell, false, true) == Surface::none, "panes without integration stay classic");

  using namespace std::chrono_literals;
  require(PendingPrompt::likely(14, 400ms) && !PendingPrompt::likely(0, 400ms) && !PendingPrompt::likely(14, 100ms), "a quiet unfinished line looks like a prompt");
}

std::vector<Style> styled(std::string_view text) {
  std::vector<Style> styles(text.size());
  classify(text, styles);
  return styles;
}

void layoutAndStyles() {
  const std::string_view command = "sudo git commit -m \"wip $USER\" | tee log # done";
  const auto styles = styled(command);
  require(styles[0] == Style::command && styles[5] == Style::command, "sudo and the command it runs are commands");
  require(styles[16] == Style::option && styles[19] == Style::string && styles[24] == Style::variable, "options, strings and variables inside them");
  require(styles[command.find('|')] == Style::operator_ && styles[command.find("tee")] == Style::command, "a pipe starts a command");
  require(styles[command.find('#')] == Style::comment, "comments");
  const auto pending = styled("gi");
  require(pending[0] == Style::pending, "the command being typed is pending");
  const auto variable = styled("echo ${HOME}/x $PATH");
  require(variable[5] == Style::variable && variable[10] == Style::variable && variable[15] == Style::variable, "variables");
  require(styled("FOO=1 make all")[6] == Style::command, "an assignment prefix leaves the command after it");
  const auto paths = styled("ls -la ./src /tmp/x y");
  require(paths[7] == Style::path && paths[13] == Style::path && paths[19] == Style::plain && paths[3] == Style::option, "arguments naming files are paths");

  // An animation group splits runs where it starts and ends, even within one style.
  const std::string grouped = "git status";
  std::vector<std::uint8_t> groups(grouped.size(), 0);
  groups[5] = 1;
  const auto split = layout(grouped, styled(grouped), grouped.size(), grouped.size(), 80, groups);
  require(split.runs.size() == 4 && split.runs[2].group == 1 && split.runs[2].start == 5 && split.runs[2].end == 6, "a group is a run of its own");

  // Wraps at the width, never cutting, and continues under the text.
  const std::string text = "echo abcdefghij";
  const auto wrapped = layout(text, styled(text), text.size(), text.size(), 10);
  require(wrapped.rows == 2 && wrapped.runs.back().row == 1 && wrapped.runs.back().column == Layout::indent, "long lines wrap under the text");
  std::uint32_t cells = 0;
  for (const auto &run : wrapped.runs) {
    cells += run.columns;
  }
  require(cells == text.size(), "every character is laid out");
  require(wrapped.caret_row == 1 && wrapped.caret_column == Layout::indent + 7, "the caret follows the text");

  const std::string lines = "for f in *; do\n  echo $f\ndone";
  const auto multiline = layout(lines, styled(lines), 0, lines.size(), 80);
  require(multiline.rows == 3 && multiline.caret_row == 0 && multiline.caret_column == Layout::indent, "newlines start rows");
  require(multiline.selection.size() == 3, "a selection spans rows");

  const std::string wide = "echo 日本";
  const auto cjk = layout(wide, styled(wide), wide.size(), wide.size(), 80);
  require(cjk.caret_column == Layout::indent + 5 + 4, "wide characters take two cells");
}

}

int main() {
  layoutAndStyles();
  routing();
  textModel();
  emacs();
  vimBasics();
  vimOperators();
  vimObjects();
  vimLines();
  vimVisual();
  std::puts("prompt editor tests passed");
}
