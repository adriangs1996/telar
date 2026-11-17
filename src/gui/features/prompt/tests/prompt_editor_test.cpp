#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>

import std;
import telar.testing;
import telar.gui.features.prompt;
import telar.gui.foundation.core;
import telar.shell.syntax;
import telar.wire.vocabulary;
import telar.wire.pane_io;

using namespace telar::gui::features::prompt;

namespace {

  namespace feature = telar::gui::features::prompt;

  // The editor the assertions drive: one pane's line at the shell's prompt, through the feature's
  // use cases, with no bindings of the user's; every read goes through its LineView.
  class Editor {
  public:
    explicit Editor(Keymap keymap = Keymap::emacs) {
      static_cast<void>(feature::open(state_, pane_id, keymap));
    }

    Outcome press(const KeyPress& key) {
      return feature::press(state_, line(), Surface::editor, key, configuration_, telar::shell::Dialect::posix);
    }

    // `command` replaces the line, the caret at its end.
    void write(std::string_view command) {
      feature::write(state_, line(), command);
    }

    // Text pasted at the caret.
    void insert(std::string_view text) {
      feature::insert(state_, line(), text);
    }

    void setClipboard(Clipboard clipboard) {
      feature::useClipboard(line(), std::move(clipboard));
    }

    [[nodiscard]] LineView view() const {
      return *feature::line(state_, pane_id);
    }

    // What the line handed its owner with its last key.
    [[nodiscard]] std::string_view delivery() {
      return feature::delivery(line());
    }

  private:
    static constexpr std::uint64_t pane_id = 1;

    PaneLine& line() {
      return *feature::find(state_, pane_id);
    }

    State state_;
    telar::gui::PromptConfiguration configuration_;
  };

  const Editor* current = nullptr;

  void require(bool condition, std::string_view message, std::source_location location = std::source_location::current()) {
    if (!condition) {
      if (current != nullptr) {
        const auto value = current->view().text();

        std::fprintf(stderr, "text: [%.*s] cursor %zu\n", static_cast<int>(value.size()), value.data(), current->view().cursor());
      }

      telar::testing::fail(message, location);
    }
  }

  // Types `keys` one by one: printable characters as themselves, `\x1b` as Escape and `\r` as
  // Enter. Returns the last outcome.
  Outcome type(Editor& editor, std::string_view keys) {
    current = &editor;
    Outcome last = Outcome::edited;

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

  Outcome control(Editor& editor, char key) {
    return editor.press({Key::character, static_cast<char32_t>(key), {.control = true}});
  }

  Outcome meta(Editor& editor, char key) {
    return editor.press({Key::character, static_cast<char32_t>(key), {.alt = true}});
  }

  std::string_view text(const Editor& editor) {
    return editor.view().text();
  }

  std::size_t cursor(const Editor& editor) {
    return editor.view().cursor();
  }

  void textModel() {
    Editor value{Keymap::vim};

    type(value, "git ");
    type(value, "status");
    require(text(value) == "git status", "typing appends");
    require(type(value, "\x1bu") == Outcome::edited && text(value).empty(), "one undo removes a run of typing");
    require(control(value, 'r') == Outcome::edited && text(value) == "git status", "redo restores it");

    Editor moving;

    moving.write("café 🙂");
    moving.press({Key::left});
    require(text(moving).substr(cursor(moving)) == "🙂", "moves by code point");
    moving.press({Key::left});
    moving.press({Key::left});
    require(cursor(moving) == 3, "a cursor never splits a code point");

    // Up and Down keep the column they started from until the next Up or Down, so the line's
    // column is set by moving across it first.
    Editor lines;

    lines.write("one\ntwo\nthree");
    control(lines, 'a');
    lines.press({Key::left});
    lines.press({Key::left});
    lines.press({Key::down});
    require(cursor(lines) == 10, "keeps a column");
    control(lines, 'a');
    lines.press({Key::left});
    control(lines, 'a');
    const auto start = cursor(lines);

    control(lines, 'e');
    require(start == 4 && cursor(lines) == 7, "finds line bounds");
    lines.press({Key::down});
    lines.press({Key::up});
    lines.press({Key::up});
    require(cursor(lines) < 4, "counts lines");

    // The text a line holds stops at 256 KiB, as Text::capacity says.
    const std::string huge(std::size_t{256} * 1024 + 1, 'x');
    Editor bounded;

    bounded.insert(huge);
    require(text(bounded).empty(), "refuses text beyond the capacity");
  }

  void emacs() {
    Editor editor;

    type(editor, "echo first");
    require(editor.press({Key::enter}) == Outcome::run && editor.delivery() == "echo first" && text(editor).empty(), "Enter asks to submit");
    type(editor, "git commit -m wip");
    require(text(editor) == "git commit -m wip", "types");
    control(editor, 'w');
    require(text(editor) == "git commit -m ", "Ctrl-W kills the word before the cursor");
    control(editor, 'y');
    require(text(editor) == "git commit -m wip", "Ctrl-Y yanks it back");
    control(editor, 'a');
    require(cursor(editor) == 0, "Ctrl-A goes to the line start");
    meta(editor, 'f');
    require(cursor(editor) == 3, "Alt-F moves past a word");
    control(editor, 'k');
    require(text(editor) == "git", "Ctrl-K kills to the end");
    control(editor, 'e');
    type(editor, "s");
    control(editor, 't');
    require(text(editor) == "gist", "Ctrl-T transposes");
    control(editor, 'u');
    require(text(editor).empty(), "Ctrl-U kills to the line start");
    require(control(editor, 'd') == Outcome::bytes && editor.delivery() == "\x04", "Ctrl-D on an empty line is end of file");

    type(editor, "for f in *; do");
    require(editor.press({Key::enter}) == Outcome::edited && text(editor) == "for f in *; do\n", "Enter continues a command the shell would read more of");
    type(editor, "  echo $f");
    editor.press({Key::enter, 0, {.alt = true}});
    require(text(editor) == "for f in *; do\n  echo $f\n", "Alt-Enter inserts a newline");
    type(editor, "done");
    require(editor.press({Key::up}) == Outcome::edited && cursor(editor) == 19, "Up moves to the line above");
    editor.press({Key::up});
    require(editor.press({Key::up}) == Outcome::edited && text(editor) == "echo first", "Up on the first line reaches the history");
    editor.press({Key::down});
    require(text(editor) == "for f in *; do\n  echo $f\ndone", "Down past the history comes back to the line");
    editor.press({Key::up});
    editor.press({Key::up});
    editor.press({Key::end});
    editor.press({Key::left, 0, {.shift = true}});
    editor.press({Key::left, 0, {.shift = true}});
    require(editor.view().anchor() != cursor(editor), "Shift extends a selection");
    type(editor, "XX");
    require(text(editor).starts_with("for f in *; XX\n"), "typing replaces the selection");
    require(control(editor, 'c') == Outcome::edited && text(editor).empty(), "Ctrl-C cancels");
    require(editor.press({Key::tab}) == Outcome::complete, "Tab completes");
    require(control(editor, 'r') == Outcome::search_history, "Ctrl-R searches the history");
  }

  Editor vim(std::string_view initial) {
    Editor editor{Keymap::vim};

    type(editor, initial);
    type(editor, "\x1b");
    return editor;
  }

  void vimBasics() {
    auto editor = vim("git switch main");

    require(editor.view().mode() == Mode::normal && cursor(editor) == 14, "Escape enters normal mode on the last character");
    type(editor, "0");
    require(cursor(editor) == 0, "0 goes to the line start");
    type(editor, "w");
    require(cursor(editor) == 4, "w moves to the next word");
    type(editor, "e");
    require(cursor(editor) == 9, "e moves to the end of the word");
    type(editor, "b");
    require(cursor(editor) == 4, "b moves back to the word start");
    type(editor, "$");
    require(cursor(editor) == 14, "$ goes to the last character");
    type(editor, "^");
    require(cursor(editor) == 0, "^ goes to the first non-blank");
    type(editor, "fm");
    require(cursor(editor) == 11, "f finds a character");
    type(editor, "0tw");
    require(cursor(editor) == 4, "t stops before a character");
    type(editor, "0ti;");
    require(cursor(editor) == 5, "; repeats t past the character it stopped at");
    require(type(editor, "\r") == Outcome::run && editor.delivery() == "git switch main", "Enter in normal mode submits");
    require(type(editor, "\x1bk") == Outcome::edited && text(editor) == "git switch main", "k on the first line reaches the history");
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
    require(text(editor) == "git restore main" && editor.view().mode() == Mode::normal, "cw changes to the word end");
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
    require(cursor(editor) == 0, "gg goes to the first line");
    type(editor, "yyjp");
    require(text(editor) == "one\ntwo\none\nthree", "yy and p copy a line below");
    type(editor, "dd");
    require(text(editor) == "one\ntwo\nthree", "dd deletes the line");
    type(editor, "G");
    require(cursor(editor) >= 8, "G goes to the last line");
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

    editor.setClipboard({.read = [&] {
                           return std::string{"pasted"};
                         },
        .write = [&](std::string_view text) {
          clipboard.assign(text);
        }});

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
    require(styled("gi")[0] == Style::command && styled("sudo gi")[5] == Style::command, "the command being typed is a command already, as the shell colours it");
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

    for (const auto& run : wrapped.runs) {
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

  const telar::testing::Case case_layout_and_styles{"prompt_editor.layout_and_styles", layoutAndStyles};
  const telar::testing::Case case_routing{"prompt_editor.routing", routing};
  const telar::testing::Case case_text_model{"prompt_editor.text_model", textModel};
  const telar::testing::Case case_emacs{"prompt_editor.emacs", emacs};
  const telar::testing::Case case_vim_basics{"prompt_editor.vim_basics", vimBasics};
  const telar::testing::Case case_vim_operators{"prompt_editor.vim_operators", vimOperators};
  const telar::testing::Case case_vim_objects{"prompt_editor.vim_objects", vimObjects};
  const telar::testing::Case case_vim_lines{"prompt_editor.vim_lines", vimLines};
  const telar::testing::Case case_vim_visual{"prompt_editor.vim_visual", vimVisual};

}
