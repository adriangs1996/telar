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
import telar.base.ds;
import telar.base.memory.allocators;

using namespace telar::gui::features::prompt;

namespace {

  namespace feature = telar::gui::features::prompt;
  using telar::Memory;

  // The memory a test's prompt lives in, counted so a test can tell it all came back.
  struct Arena {
    Arena() = default;
    ~Arena() = default;
    Arena(const Arena&) = delete;
    Arena& operator=(const Arena&) = delete;
    Arena(Arena&&) = delete;
    Arena& operator=(Arena&&) = delete;

    telar::SystemAllocator system;
    telar::BudgetAllocator<telar::SystemAllocator> budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter<telar::BudgetAllocator<telar::SystemAllocator>> memory{budget};
  };

  // The editor the assertions drive: one pane's line at the shell's prompt, through the feature's
  // use cases, with no bindings of the user's; every read goes through its LineView. It stays
  // where it is made: its state points at its arena.
  class Editor : Arena {
  public:
    explicit Editor(Keymap keymap = Keymap::emacs)
        : state_(memory),
          lines_(memory) {
      static_cast<void>(feature::open(state_, lines_, pane_id, keymap));
    }

    // A command handed over is sent at once, as the owner does when the shell takes it.
    Outcome press(const KeyPress& key) {
      const auto outcome = feature::press(state_, line(), Surface::editor, key, {.configuration = configuration_, .dialect = telar::shell::Dialect::posix});
      if (outcome == Outcome::run || outcome == Outcome::answer) {
        const telar::ds::String<Memory> sent{memory, outcome == Outcome::run ? feature::delivery(line()) : std::string_view{}};

        feature::committed(line(), sent.view());
      }

      return outcome;
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
      return *feature::line(state_, lines_, pane_id);
    }

    // What the line handed its owner with its last key.
    [[nodiscard]] std::string_view delivery() {
      return feature::delivery(line());
    }

  private:
    static constexpr std::uint64_t pane_id = 1;

    PaneLine& line() {
      return *feature::find(lines_, pane_id);
    }

    State state_;
    feature::Lines lines_;
    telar::gui::PromptConfiguration configuration_;
  };

  // The editor `type` drove last, whose line a failed requirement prints.
  const Editor*& current() {
    static const Editor* editor = nullptr;

    return editor;
  }

  void require(bool condition, std::string_view message, std::source_location location = std::source_location::current()) {
    if (!condition) {
      if (const auto* editor = current(); editor != nullptr) {
        std::println(stderr, "text: [{}] cursor {}", editor->view().text(), editor->view().cursor());
      }

      telar::testing::fail(message, location);
    }
  }

  // Types `keys` one by one: printable characters as themselves, `\x1b` as Escape and `\r` as
  // Enter. Returns the last outcome.
  Outcome type(Editor& editor, std::string_view keys) {
    current() = &editor;
    Outcome last = Outcome::edited;

    for (std::size_t index = 0; index < keys.size(); ++index) {
      const auto byte = keys[index];
      if (byte == '\x1b') {
        last = editor.press({.key = Key::escape});
      } else if (byte == '\r') {
        last = editor.press({.key = Key::enter});
      } else {
        last = editor.press({.key = Key::character, .character = static_cast<char32_t>(static_cast<unsigned char>(byte)), .text = keys.substr(index, 1)});
      }
    }

    return last;
  }

  Outcome control(Editor& editor, char key) {
    return editor.press({.key = Key::character, .character = static_cast<char32_t>(key), .modifiers = {.control = true}});
  }

  Outcome meta(Editor& editor, char key) {
    return editor.press({.key = Key::character, .character = static_cast<char32_t>(key), .modifiers = {.alt = true}});
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
    moving.press({.key = Key::left});
    require(text(moving).substr(cursor(moving)) == "🙂", "moves by code point");
    moving.press({.key = Key::left});
    moving.press({.key = Key::left});
    require(cursor(moving) == 3, "a cursor never splits a code point");

    // Up and Down keep the column they started from until the next Up or Down, so the line's
    // column is set by moving across it first.
    Editor lines;
    // Offsets into the three lines: the second spans [4, 7), the third starts at 8.
    constexpr std::size_t third_line_column_two = 10;
    constexpr std::size_t second_line_end = 7;

    lines.write("one\ntwo\nthree");
    control(lines, 'a');
    lines.press({.key = Key::left});
    lines.press({.key = Key::left});
    lines.press({.key = Key::down});
    require(cursor(lines) == third_line_column_two, "keeps a column");
    control(lines, 'a');
    lines.press({.key = Key::left});
    control(lines, 'a');
    const auto start = cursor(lines);

    control(lines, 'e');
    require(start == 4 && cursor(lines) == second_line_end, "finds line bounds");
    lines.press({.key = Key::down});
    lines.press({.key = Key::up});
    lines.press({.key = Key::up});
    require(cursor(lines) < 4, "counts lines");

    // The text a line holds stops at 64 KiB, as Text::capacity says.
    constexpr std::size_t capacity = std::size_t{64} * 1024;
    Arena arena;
    telar::ds::String<Memory> huge{arena.memory};
    Editor bounded;

    huge.resize(capacity + 1, 'x');
    bounded.insert(huge.view());
    require(text(bounded).empty(), "refuses text beyond the capacity");
  }

  // A command pasted from the history search starts Up and Down over: Down keeps it instead of
  // bringing back a draft from before the paste.
  void writeStartsHistoryOver() {
    Editor editor;

    for (const auto* command : {"echo one", "echo two"}) {
      type(editor, command);
      static_cast<void>(editor.press({.key = Key::enter}));
    }

    static_cast<void>(editor.press({.key = Key::up}));
    static_cast<void>(editor.press({.key = Key::up}));
    require(text(editor) == "echo one", "Up walks back");
    editor.write("ls -la");
    static_cast<void>(editor.press({.key = Key::down}));
    require(text(editor) == "ls -la", "Down after a paste keeps it");
    static_cast<void>(editor.press({.key = Key::up}));
    require(text(editor) == "echo two", "Up after a paste starts from the newest");
  }

  void emacs() {
    Editor editor;

    type(editor, "echo first");
    require(editor.press({.key = Key::enter}) == Outcome::run && editor.delivery() == "echo first" && text(editor).empty(), "Enter asks to submit");
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
    require(editor.press({.key = Key::enter}) == Outcome::edited && text(editor) == "for f in *; do\n", "Enter continues a command the shell would read more of");
    type(editor, "  echo $f");
    editor.press({.key = Key::enter, .modifiers = {.alt = true}});
    require(text(editor) == "for f in *; do\n  echo $f\n", "Alt-Enter inserts a newline");
    type(editor, "done");
    // The end of `done`, column 4, on the line above.
    constexpr std::size_t above_done_end = 19;

    require(editor.press({.key = Key::up}) == Outcome::edited && cursor(editor) == above_done_end, "Up moves to the line above");
    editor.press({.key = Key::up});
    require(editor.press({.key = Key::up}) == Outcome::edited && text(editor) == "echo first", "Up on the first line reaches the history");
    editor.press({.key = Key::down});
    require(text(editor) == "for f in *; do\n  echo $f\ndone", "Down past the history comes back to the line");
    editor.press({.key = Key::up});
    editor.press({.key = Key::up});
    editor.press({.key = Key::end});
    editor.press({.key = Key::left, .modifiers = {.shift = true}});
    editor.press({.key = Key::left, .modifiers = {.shift = true}});
    require(editor.view().anchor() != cursor(editor), "Shift extends a selection");
    type(editor, "XX");
    require(text(editor).starts_with("for f in *; XX\n"), "typing replaces the selection");
    require(control(editor, 'c') == Outcome::edited && text(editor).empty(), "Ctrl-C cancels");
    require(editor.press({.key = Key::tab}) == Outcome::complete, "Tab completes");
    require(control(editor, 'r') == Outcome::search_history, "Ctrl-R searches the history");
  }

  // A vim line holding `initial`, back in normal mode.
  void start(Editor& editor, std::string_view initial) {
    type(editor, initial);
    type(editor, "\x1b");
  }

  void vimBasics() {
    Editor editor{Keymap::vim};
    constexpr std::string_view line = "git switch main";
    constexpr auto last = line.size() - 1;
    constexpr auto second_word = line.find("switch");
    constexpr auto second_word_end = line.find(" main") - 1;

    start(editor, line);

    require(editor.view().mode() == Mode::normal && cursor(editor) == last, "Escape enters normal mode on the last character");
    type(editor, "0");
    require(cursor(editor) == 0, "0 goes to the line start");
    type(editor, "w");
    require(cursor(editor) == second_word, "w moves to the next word");
    type(editor, "e");
    require(cursor(editor) == second_word_end, "e moves to the end of the word");
    type(editor, "b");
    require(cursor(editor) == second_word, "b moves back to the word start");
    type(editor, "$");
    require(cursor(editor) == last, "$ goes to the last character");
    type(editor, "^");
    require(cursor(editor) == 0, "^ goes to the first non-blank");
    type(editor, "fm");
    require(cursor(editor) == line.find('m'), "f finds a character");
    type(editor, "0tw");
    require(cursor(editor) == second_word, "t stops before a character");
    type(editor, "0ti;");
    require(cursor(editor) == line.find("itch") - 1, "; repeats t past the character it stopped at");
    require(type(editor, "\r") == Outcome::run && editor.delivery() == line, "Enter in normal mode submits");
    require(type(editor, "\x1bk") == Outcome::edited && text(editor) == line, "k on the first line reaches the history");
  }

  void vimOperators() {
    Editor editor{Keymap::vim};

    start(editor, "git switch main");

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
    Editor editor{Keymap::vim};

    start(editor, "echo \"hello world\" (a (b) c)");

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
    constexpr std::string_view three_lines = "one\ntwo\nthree";

    type(editor, three_lines);
    type(editor, "\x1bgg");
    require(cursor(editor) == 0, "gg goes to the first line");
    type(editor, "yyjp");
    require(text(editor) == "one\ntwo\none\nthree", "yy and p copy a line below");
    type(editor, "dd");
    require(text(editor) == three_lines, "dd deletes the line");
    type(editor, "G");
    require(cursor(editor) > three_lines.rfind('\n'), "G goes to the last line");
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
    Editor editor{Keymap::vim};

    start(editor, "git log --oneline");

    type(editor, "0wviwd");
    require(text(editor) == "git  --oneline", "v with a text object selects and deletes");
    type(editor, "0vey$p");
    require(text(editor) == "git  --onelinegit", "visual y yanks the selection");
    Arena arena;
    telar::ds::String<Memory> clipboard{arena.memory};

    editor.setClipboard({
        .read = [](telar::ds::String<Memory>& text) {
          text.assign("pasted");
        },
        .write = [&](std::string_view text) {
          clipboard.assign(text);
        },
    });

    type(editor, "0\"+yiw");
    require(clipboard.view() == "git", "the + register writes the system clipboard");
    type(editor, "$\"+p");
    require(text(editor).ends_with("pasted"), "the + register reads it");
  }

  void routing() {
    // The line discipline's defaults: Ctrl-C, Ctrl-\, Ctrl-Z and Ctrl-D.
    constexpr telar::Byte interrupt = 0x03;
    constexpr telar::Byte quit = 0x1c;
    constexpr telar::Byte suspend = 0x1a;
    constexpr telar::Byte end_of_file = 0x04;
    telar::PaneShell shell{.pane_id = 1, .shell = telar::IntegratedShell::zsh, .phase = telar::ShellPhase::prompt, .shell_foreground = true, .canonical = false, .echo = false, .signal_keys = false, .interrupt = interrupt, .quit = quit, .suspend = suspend, .end_of_file = end_of_file};

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

    constexpr std::uint32_t prompt_column = 14;
    constexpr auto quiet = 400ms;
    constexpr auto busy = 100ms;

    require(PendingPrompt::likely(prompt_column, quiet) && !PendingPrompt::likely(0, quiet) && !PendingPrompt::likely(prompt_column, busy), "a quiet unfinished line looks like a prompt");
  }

  telar::ds::Vec<Style, Memory> styleOf(Memory& memory, std::string_view text) {
    telar::ds::Vec<Style, Memory> styles{memory};
    telar::ds::Vec<telar::shell::Token, Memory> tokens{memory};

    styles.resize(text.size());
    classify(text, styles.viewMut(), tokens);
    return styles;
  }

  void layoutAndStyles() {
    Arena arena;
    auto& memory = arena.memory;
    const auto styled = [&memory](std::string_view text) {
      return styleOf(memory, text);
    };

    const auto layout = [&memory](const feature::StyledText& text, feature::Selection selection, std::uint32_t columns) {
      Layout result{memory};

      feature::layout(result, text, selection, columns);
      return result;
    };

    const std::string_view command = "sudo git commit -m \"wip $USER\" | tee log # done";
    const auto styles = styled(command);

    require(styles[0] == Style::command && styles[command.find("git")] == Style::command, "sudo and the command it runs are commands");
    require(styles[command.find("-m")] == Style::option && styles[command.find('"')] == Style::string && styles[command.find('$')] == Style::variable, "options, strings and variables inside them");
    require(styles[command.find('|')] == Style::shell_operator && styles[command.find("tee")] == Style::command, "a pipe starts a command");
    require(styles[command.find('#')] == Style::comment, "comments");
    const std::string_view typing = "sudo gi";

    require(styled("gi")[0] == Style::command && styled(typing)[typing.find("gi")] == Style::command, "the command being typed is a command already, as the shell colours it");
    const std::string_view expansions = "echo ${HOME}/x $PATH";
    const auto variable = styled(expansions);

    require(variable[expansions.find('$')] == Style::variable && variable[expansions.find('}') - 1] == Style::variable && variable[expansions.rfind('$')] == Style::variable, "variables");
    const std::string_view assignment = "FOO=1 make all";

    require(styled(assignment)[assignment.find("make")] == Style::command, "an assignment prefix leaves the command after it");
    const std::string_view arguments = "ls -la ./src /tmp/x y";
    const auto paths = styled(arguments);

    require(paths[arguments.find("./src")] == Style::path && paths[arguments.find("/tmp")] == Style::path && paths[arguments.rfind(' ')] == Style::plain && paths[arguments.find("-la")] == Style::option, "arguments naming files are paths");

    // An animation group splits runs where it starts and ends, even within one style.
    const std::string_view grouped = "git status";
    constexpr std::size_t grouped_byte = 5;
    telar::ds::Vec<std::uint8_t, Memory> groups{memory};

    groups.resize(grouped.size(), 0);
    groups.atMut(grouped_byte) = 1;
    const auto split = layout({.text = grouped, .styles = styled(grouped).view(), .groups = groups.view()}, {.cursor = grouped.size(), .anchor = grouped.size()}, 80);

    require(split.runs.size() == 4 && split.runs[2].group == 1 && split.runs[2].start == grouped_byte && split.runs[2].end == grouped_byte + 1, "a group is a run of its own");

    // Wraps at the width, never cutting, and continues under the text.
    const std::string_view text = "echo abcdefghij";
    const auto wrapped = layout({.text = text, .styles = styled(text).view()}, {.cursor = text.size(), .anchor = text.size()}, 10);

    require(wrapped.rows == 2 && wrapped.runs.back().row == 1 && wrapped.runs.back().column == Layout::indent, "long lines wrap under the text");
    std::uint32_t cells = 0;

    for (const auto& run : wrapped.runs) {
      cells += run.columns;
    }

    require(cells == text.size(), "every character is laid out");
    // The caret ends after `abcdefghij`, which wrapped to the second row.
    constexpr std::uint32_t wrapped_caret_column = 7;

    require(wrapped.caret_row == 1 && wrapped.caret_column == Layout::indent + wrapped_caret_column, "the caret follows the text");

    const std::string_view lines = "for f in *; do\n  echo $f\ndone";
    const auto multiline = layout({.text = lines, .styles = styled(lines).view()}, {.cursor = 0, .anchor = lines.size()}, 80);

    require(multiline.rows == 3 && multiline.caret_row == 0 && multiline.caret_column == Layout::indent, "newlines start rows");
    require(multiline.selection.size() == 3, "a selection spans rows");

    const std::string_view wide = "echo 日本";
    constexpr std::uint32_t echo_cells = 5;
    constexpr std::uint32_t cjk_cells = 4;
    const auto cjk = layout({.text = wide, .styles = styled(wide).view()}, {.cursor = wide.size(), .anchor = wide.size()}, 80);

    require(cjk.caret_column == Layout::indent + echo_cells + cjk_cells, "wide characters take two cells");

    // A caret inside a grapheme is drawn on that grapheme, never at the line's start.
    const std::string_view accented = "cafe\u0301";
    const auto inside = layout({.text = accented, .styles = styled(accented).view()}, {.cursor = accented.size() - 1, .anchor = accented.size() - 1}, 80);

    require(inside.caret_column == Layout::indent + 3, "the caret sits on the grapheme it is inside");

    // A command of more runs than a layout keeps still shows the rows around its caret.
    std::string long_command;

    for (int index = 0; index < 3000; ++index) {
      long_command += "a 'b' ";
    }

    const auto far = layout({.text = long_command, .styles = styled(long_command).view()}, {.cursor = long_command.size(), .anchor = long_command.size()}, 40);
    const auto shown = std::ranges::count_if(far.runs, [&](const Run& run) {
      return run.row == far.caret_row;
    });

    require(far.caret_row + 1 == far.rows && shown > 0, "the caret's row has its runs");
  }

  // Left, Right and Backspace move over a grapheme, an accent written apart or a flag whole.
  void graphemeMotions() {
    Editor editor;

    editor.insert("cafe\u0301");
    static_cast<void>(editor.press({.key = Key::left}));
    require(cursor(editor) == 3, "Left steps over the accented letter");
    static_cast<void>(editor.press({.key = Key::right}));
    require(cursor(editor) == text(editor).size(), "Right steps over it");
    static_cast<void>(editor.press({.key = Key::backspace}));
    require(text(editor) == "caf", "Backspace erases the letter with its accent");
    editor.insert("\U0001F1EA\U0001F1F8");
    static_cast<void>(editor.press({.key = Key::left}));
    require(cursor(editor) == 3, "a flag is one step");
  }

  // What the line holds (its text, undo, registers and the commands it ran) lives in the memory
  // it was given, and all of it goes back once the state is gone.
  void memoryReturns() {
    Arena arena;

    {
      State state{arena.memory};
      feature::Lines lines{arena.memory};
      auto& line = feature::open(state, lines, 1, Keymap::vim).line;
      const telar::gui::PromptConfiguration configuration;

      for (const char byte : std::string_view{"iecho one two\x1b"
                                              "0dwP\"ayiwu\x12"
                                              "A three\r"}) {
        KeyPress key{.key = Key::character, .character = static_cast<char32_t>(byte), .text = std::string_view{&byte, 1}};

        if (byte == '\x1b') {
          key = {.key = Key::escape};
        } else if (byte == '\r') {
          key = {.key = Key::enter};
        } else if (byte == '\x12') {
          key = {.key = Key::character, .character = U'r', .modifiers = {.control = true}};
        }

        static_cast<void>(feature::press(state, line, Surface::editor, key, {.configuration = configuration, .dialect = telar::shell::Dialect::posix}));
      }

      feature::remember(state, feature::delivery(line));
      feature::remember(state, "git status");
      require(feature::history(state).size() == 2, "the commands it ran are remembered");
      require(arena.budget.liveBytes() > 0, "the line lives in the memory it was given");
    }

    require(arena.budget.liveBytes() == 0, "the line gives all of it back");
  }

  const telar::testing::Case case_write_starts_history_over{"prompt_editor.write_starts_history_over", writeStartsHistoryOver};
  const telar::testing::Case case_grapheme_motions{"prompt_editor.grapheme_motions", graphemeMotions};
  const telar::testing::Case case_memory_returns{"prompt_editor.memory_returns", memoryReturns};
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
