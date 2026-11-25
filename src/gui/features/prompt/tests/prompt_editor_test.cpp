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

    // An arena that refuses what passes `limit` bytes.
    explicit Arena(std::size_t limit)
        : budget{system, limit} {}

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

    // An editor whose memory refuses what passes `limit` bytes.
    Editor(Keymap keymap, std::size_t limit)
        : Arena(limit),
          state_(memory),
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

    // The pane printed at `now`, in nanoseconds of the clock the routing reads.
    void output(std::int64_t now) {
      feature::output(lines_, pane_id, [now] {
        return now;
      });
    }

    // Whether `key`, typed at `now` with the program's cursor at `column`, reaches the program.
    [[nodiscard]] bool toProgram(const KeyPress& key, const telar::PaneShell& shell, std::uint32_t column, std::int64_t now) {
      return feature::toProgram(line(), key, shell, column, [now] {
        return now;
      });
    }

    // Whether `text`, committed or pasted at `now`, reaches the program.
    [[nodiscard]] bool toProgram(std::string_view text, std::uint32_t column, std::int64_t now) {
      return feature::toProgram(line(), text, column, [now] {
        return now;
      });
    }

    void follow(const telar::PaneShell& previous, const telar::PaneShell& current) {
      static_cast<void>(feature::follow(line(), previous, current, 0));
    }

    // A key while a program runs, as the queue reads it.
    Outcome pressRunning(const KeyPress& key) {
      return feature::press(state_, line(), Surface::running, key, {.configuration = configuration_, .dialect = telar::shell::Dialect::posix});
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

  // The column Up and Down keep is forgotten by any other motion, as readline's is.
  void emacsGoalColumn() {
    Editor editor;

    editor.write("abcdef\nabcdef\nab");
    control(editor, 'a');
    static_cast<void>(editor.press({.key = Key::up}));
    require(cursor(editor) == 7, "Up keeps the column");
    control(editor, 'e');
    static_cast<void>(editor.press({.key = Key::down}));
    require(cursor(editor) == 16, "after Ctrl-E, Down goes from the line's end, not the column before");
  }

  // An undo step keeps what it changed, not the whole text: many small edits of a long command
  // hold little, and undo and redo still bring each state back.
  void undoKeepsChanges() {
    constexpr std::size_t budget = std::size_t{2} * 1024 * 1024;
    constexpr std::size_t length = std::size_t{60} * 1024;
    Editor editor{Keymap::emacs, budget};
    const std::string long_text(length, 'x');

    editor.write(long_text);
    for (int index = 0; index < 200; ++index) {
      control(editor, 'a');
      type(editor, "y");
    }

    require(text(editor).size() == length + 200, "every edit took");
    for (int index = 0; index < 200; ++index) {
      control(editor, '_');
    }

    require(text(editor) == long_text, "undo brings the text back");
    type(editor, "ab");
    static_cast<void>(editor.press({.key = Key::backspace}));
    type(editor, "c");
    control(editor, '_');
    require(text(editor) == "a" + long_text, "undo takes the last typing back");
    control(editor, '_');
    require(text(editor) == "ab" + long_text, "then the erasure");
    control(editor, '_');
    require(text(editor) == long_text, "then the first typing");

    // Redo brings each step forward again.
    Editor vim{Keymap::vim};

    type(vim, "one two");
    type(vim, "\x1b"
              "0dwxu");
    require(text(vim) == "two", "undo takes the last change back");
    control(vim, 'r');
    require(text(vim) == "wo", "redo brings it again");
    type(vim, "uu");
    require(text(vim) == "one two", "undo goes back through every step");
  }

  // Kills in a row join one kill ring entry, the ones backward before it, as readline's do.
  void emacsKillsAccumulate() {
    Editor backward;

    type(backward, "one two three");
    control(backward, 'w');
    control(backward, 'w');
    require(text(backward) == "one ", "two words killed");
    control(backward, 'y');
    require(text(backward) == "one two three", "two Ctrl-W in a row yank back as one");

    Editor forward;

    forward.write("a\nb");
    control(forward, 'p');
    control(forward, 'a');
    control(forward, 'k');
    control(forward, 'k');
    require(text(forward) == "b", "the line and its newline killed");
    control(forward, 'y');
    require(text(forward) == "a\nb", "Ctrl-K in a row append to one kill");

    control(forward, 'e');
    control(forward, 'w');
    control(forward, 'y');
    require(text(forward) == "a\nb", "a kill after another key starts anew");
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

  // Behaviours that differed from vim's, each as vim has it.
  void vimFixes() {
    // Vjd deletes both lines the selection spans.
    {
      Editor editor{Keymap::vim};

      type(editor, "one\ntwo\nthree");
      type(editor, "\x1bggVjd");
      require(text(editor) == "three", "Vjd deletes the two lines");
    }

    // dd on the last line keeps the line, whole, for p to paste back as a line.
    {
      Editor editor{Keymap::vim};

      type(editor, "a\nb");
      type(editor, "\x1bGdd");
      require(text(editor) == "a", "dd deletes the last line with the newline before it");
      type(editor, "p");
      require(text(editor) == "a\nb", "p puts it back as a line below");
      type(editor, "ggP");
      require(text(editor) == "b\na\nb", "P puts it as a line above");
    }

    // Changing case or indent keeps what was yanked.
    {
      Editor editor{Keymap::vim};

      start(editor, "abc");
      type(editor, "0yl~>><<");
      type(editor, "$p");
      require(text(editor) == "Abca", "~, >> and << leave the unnamed register alone");
    }

    // dw on a line's last word stops at the line's end instead of joining the next line.
    {
      Editor editor{Keymap::vim};

      type(editor, "one two\nthree");
      type(editor, "\x1bgg$bdw");
      require(text(editor) == "one \nthree", "dw deletes the last word alone");
    }

    // ge goes back to the end of the word before, and dge deletes through it.
    {
      Editor editor{Keymap::vim};

      start(editor, "one two three");
      type(editor, "0fhge");
      require(cursor(editor) == 6, "ge goes to the end of the word before");
      type(editor, "fhdge");
      require(text(editor) == "one twree", "dge deletes from there through the cursor");
    }

    // ; after T skips the character T stopped after, as it does after t.
    {
      Editor editor{Keymap::vim};

      start(editor, "a,b,c");
      type(editor, "$T,");
      require(cursor(editor) == 4, "T, right after the comma stays");
      type(editor, ";");
      require(cursor(editor) == 2, "; goes on to the comma before");
    }

    // $ on an empty line reaches no character: d$ there keeps the line's newline.
    {
      Editor editor{Keymap::vim};

      type(editor, "a\n\nb");
      type(editor, "\x1bggjd$");
      require(text(editor) == "a\n\nb", "d$ on an empty line deletes nothing");
    }

    // An insert is one undo step, from the command that began it to Escape, erasures included.
    {
      Editor editor{Keymap::vim};

      start(editor, "one two");
      type(editor, "0cwxyz\x1bu");
      require(text(editor) == "one two", "cw and what it typed undo together");
      type(editor, "oabc\x1bu");
      require(text(editor) == "one two", "o and what it typed undo together");
      type(editor, "$aabc");
      static_cast<void>(editor.press({.key = Key::backspace}));
      type(editor, "d\x1bu");
      require(text(editor) == "one two", "a Backspace inside the insert does not split it");
    }

    // r followed by a key that types nothing is cancelled, the text left alone.
    {
      Editor editor{Keymap::vim};

      start(editor, "abc");
      for (const auto key : {Key::backspace, Key::left, Key::delete_forward}) {
        type(editor, "0r");
        static_cast<void>(editor.press({.key = key}));
        require(text(editor) == "abc", "r with a key that types nothing changes nothing");
      }

      type(editor, "0rx");
      require(text(editor) == "xbc", "r still replaces with a character");
    }

    // A put that could not fit builds nothing first: 9999p of a large register does not try to
    // hold thousands of copies of it.
    {
      constexpr std::size_t budget = std::size_t{4} * 1024 * 1024;
      Editor editor{Keymap::vim, budget};

      editor.write(std::string(std::size_t{32} * 1024, 'x'));
      type(editor, "\x1b"
                   "0yy9999p");
      require(text(editor).size() == std::size_t{32} * 1024, "a put past the capacity changes nothing");
    }

    // The smaller ones.
    {
      Editor editor{Keymap::vim};

      start(editor, "a b c d e f g");
      type(editor, "02dw3.");
      require(text(editor) == "f g", "a count before . replaces the change's own");
    }

    {
      Editor editor{Keymap::vim};

      start(editor, "one two");
      type(editor, "0wyy");
      require(cursor(editor) == 4, "yy keeps the cursor");
      type(editor, "Y");
      require(cursor(editor) == 4, "Y keeps the cursor");
    }

    {
      Editor editor{Keymap::vim};

      type(editor, "a\nb\nc");
      type(editor, "\x1bgg5j");
      require(cursor(editor) == 4, "5j with fewer lines below goes to the last");
    }

    {
      Editor editor{Keymap::vim};

      start(editor, "ab");
      type(editor, "0vlllld");
      require(text(editor).empty(), "visual l stops at the last character");
    }

    {
      Editor editor{Keymap::vim};

      type(editor, "one\ntwo");
      type(editor, "\x1bggyyjVp");
      require(text(editor) == "one\none", "V with a line register replaces the line with it");
      type(editor, "ggyyGvep");
      require(text(editor) == "one\n\none\n", "v with a line register puts the line apart");
      type(editor, "ggP");
      require(text(editor) == "oneone\n\none\n", "the replaced text, charwise, is in the unnamed register");
    }

    // What a visual mode highlights is what d takes: v both ends' characters, V whole lines.
    {
      Editor editor{Keymap::vim};

      type(editor, "abc\ndef");
      type(editor, "\x1bgg0vl");
      const auto characters = editor.view().highlight();

      require(characters && characters->first == 0 && characters->second == 2, "v highlights both ends' characters");
      type(editor, "o");
      const auto swapped = editor.view().highlight();

      require(swapped && swapped->first == 0 && swapped->second == 2, "and the anchor's after o");
      type(editor, "\x1bVj");
      const auto lines = editor.view().highlight();

      require(lines && lines->first == 0 && lines->second == 7, "V highlights whole lines");
      type(editor, "\x1b");
      require(!editor.view().highlight(), "nothing is highlighted outside them");
    }
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

  // A program's question takes the whole answer typed at it, however fast: the echo of each key
  // is output, which must not send the next one to the queue.
  void answerFollowsItsFirstKey() {
    using namespace std::chrono_literals;

    constexpr std::uint32_t question_column = 17;
    constexpr std::int64_t asked = 0;
    constexpr std::int64_t quiet = std::chrono::nanoseconds{400ms}.count();
    constexpr std::int64_t moment = std::chrono::nanoseconds{10ms}.count();
    const telar::PaneShell shell{.pane_id = 1, .shell = telar::IntegratedShell::zsh, .phase = telar::ShellPhase::running, .canonical = true, .echo = true, .signal_keys = true, .interrupt = 0x03, .quit = 0x1c, .suspend = 0x1a, .end_of_file = 0x04};
    const auto key = [](char character) {
      return KeyPress{.key = Key::character, .character = static_cast<char32_t>(character)};
    };
    const KeyPress enter{.key = Key::enter};
    Editor editor;

    // terraform's "Enter a value: ", quiet; "yes" typed as each key's echo arrives.
    editor.output(asked);
    require(editor.toProgram(key('y'), shell, question_column, quiet), "the first key answers the quiet question");
    editor.output(quiet + moment);
    require(editor.toProgram(key('e'), shell, question_column + 1, quiet + (2 * moment)), "the key after the echo follows it");
    editor.output(quiet + (3 * moment));
    require(editor.toProgram(key('s'), shell, question_column + 2, quiet + (4 * moment)), "so does the rest of the answer");
    require(editor.toProgram(enter, shell, question_column + 3, quiet + (5 * moment)), "Enter sends the answer");
    editor.output(quiet + (6 * moment));
    require(!editor.toProgram(key('l'), shell, question_column, quiet + (7 * moment)), "after Enter, a program that prints queues the keys again");

    // A signal ends the line being read, and so does a program that stops reading one.
    editor.output(asked);
    require(editor.toProgram(key('n'), shell, question_column, quiet), "a new answer starts");
    require(editor.toProgram(KeyPress{.key = Key::character, .character = U'c', .modifiers = {.control = true}}, shell, question_column, quiet + moment), "Ctrl-C reaches the program");
    editor.output(quiet + (2 * moment));
    require(!editor.toProgram(key('a'), shell, question_column, quiet + (3 * moment)), "Ctrl-C ends the answer");
    editor.output(asked);
    require(editor.toProgram(key('n'), shell, question_column, quiet), "another answer starts");

    auto raw = shell;

    raw.canonical = false;
    editor.follow(shell, raw);
    editor.output(quiet + moment);
    require(!editor.toProgram(key('a'), shell, question_column, quiet + (2 * moment)), "a program that reads keys raw ends the answer");

    // A paste or an input method's text answers as keys do; a newline at its end ends it.
    editor.output(asked);
    require(editor.toProgram("ye", question_column, quiet), "a paste answers the quiet question");
    editor.output(quiet + moment);
    require(editor.toProgram(key('s'), shell, question_column + 2, quiet + (2 * moment)), "keys follow the paste");
    require(editor.toProgram(enter, shell, question_column + 3, quiet + (3 * moment)), "Enter ends it");
    editor.output(asked);
    require(editor.toProgram("yes\n", question_column, quiet), "a paste with its newline answers");
    editor.output(quiet + moment);
    require(!editor.toProgram("ls", question_column, quiet + (2 * moment)), "and ends the answer");
    editor.output(asked);
    require(!editor.toProgram("yes\nrm -rf ~", question_column, quiet), "lines after the first stay in the line, which the shell would run");
    require(oneLine("yes\r\n") == std::string_view{"yes"} && !oneLine("a\nb") && oneLine("") == std::string_view{}, "one line is what is left without its ends");

    // Text in the queue keeps the keys there.
    editor.output(asked);
    static_cast<void>(editor.pressRunning({.key = Key::character, .character = U'l', .text = "l"}));
    require(!text(editor).empty(), "the key queues");
    require(!editor.toProgram(key('s'), shell, question_column, quiet), "a command being queued keeps its keys");
    require(editor.toProgram(KeyPress{.key = Key::character, .character = U'c', .modifiers = {.control = true}}, shell, question_column, quiet), "Ctrl-C still reaches the program");
  }

  // Up walks past a command of several lines, between whose lines it moves first, and Down comes
  // back to what was being written; moving the caret in what Up brought back keeps its place.
  void historyCrossesLongCommands() {
    Editor editor;
    const KeyPress up{.key = Key::up};
    const KeyPress down{.key = Key::down};

    editor.write("older");
    require(editor.press({.key = Key::enter}) == Outcome::run, "a command runs");
    editor.write("echo 'a\nb'");
    require(editor.press({.key = Key::enter}) == Outcome::run, "a command of two lines runs");
    type(editor, "draft");
    editor.press(up);
    require(text(editor) == "echo 'a\nb'", "Up brings back the last command");
    editor.press(up);
    require(text(editor) == "echo 'a\nb'" && cursor(editor) < 7, "Up moves to its first line");
    editor.press(up);
    require(text(editor) == "older", "and then past it");
    editor.press(down);
    editor.press(down);
    require(text(editor) == "draft", "Down comes back to the draft");

    editor.press(up);
    editor.press(up);
    editor.press(up);
    editor.press({.key = Key::left});
    editor.press(up);
    require(text(editor) == "older", "moving the caret keeps the place in the history");
    type(editor, "x");
    editor.press(up);
    require(text(editor) == "echo 'a\nb'", "an edit makes it the line being written");
  }

  // Fixes to vim's keys: Enter on a command that goes on, counts, registers, the case operators
  // and the dot.
  void vimCommands() {
    {
      Editor editor{Keymap::vim};

      type(editor, "echo \"foo\x1b");
      require(editor.press({.key = Key::enter}) == Outcome::edited && text(editor) == "echo \"foo\n" && editor.view().mode() == Mode::insert, "Enter in normal mode goes on after the text, in insert mode");
    }
    {
      Editor editor{Keymap::vim};

      type(editor, "abc\x1b"
                   "0");
      type(editor, "9999d9999l");
      require(text(editor).empty(), "a count past what is there stops at the line's end");
    }
    {
      Editor editor{Keymap::vim};

      type(editor, "one two\x1b"
                   "0\"ayww\"Ayw0\"aP");
      require(text(editor) == "one twoone two", "an uppercase register appends");
    }
    {
      Editor editor{Keymap::vim};

      type(editor, "a b c d e f g\x1b"
                   "0d3w");
      require(text(editor) == "d e f g", "d3w deletes three words");
      type(editor, "2.");
      require(text(editor) == "f g", "2. deletes two, its count replacing the operator's");
    }
    {
      Editor editor{Keymap::vim};

      type(editor, "ABC def\x1b"
                   "0guw");
      require(text(editor) == "abc def", "gu lowers a word");
      type(editor, "wgUiw");
      require(text(editor) == "abc DEF", "gU raises one");
      type(editor, "0g~~");
      require(text(editor) == "ABC def", "g~~ swaps the line's case");
      type(editor, "0gUw");
      type(editor, "w.");
      require(text(editor) == "ABC DEF", "the dot repeats a case operator");
      type(editor, "0vegu");
      require(text(editor) == "abc DEF", "gu over a selection lowers it");
    }
    {
      Editor editor{Keymap::vim};

      type(editor, "ls -la\r\x1b");
      editor.press({.key = Key::character, .character = U'k', .text = "k"});
      require(text(editor) == "ls -la" && cursor(editor) == 5, "a command k brings back sits on its last character");
      type(editor, "x");
      require(text(editor) == "ls -l", "where x deletes it");
    }
  }

  // Ctrl-_ takes back a word typed at a time, as readline does.
  void emacsUndoesWords() {
    Editor editor;

    type(editor, "echo hello world");
    control(editor, '_');
    require(text(editor) == "echo hello ", "undo takes back the last word");
    control(editor, '_');
    require(text(editor) == "echo ", "and the one before");
  }

  // A byte that starts no character, as Latin-1 a history kept brings, is one to move over and
  // delete.
  void invalidBytesAreCharacters() {
    Editor editor;

    editor.write("a\x80"
                 "b");
    editor.press({.key = Key::home});
    editor.press({.key = Key::right});
    editor.press({.key = Key::right});
    require(cursor(editor) == 2, "Right crosses the stray byte");
    editor.press({.key = Key::left});
    editor.press({.key = Key::delete_forward});
    require(text(editor) == "ab", "Delete removes it");
  }

  // A command the lexer cannot follow to its end is the shell's to judge: Enter runs it.
  void deepCommandsRun() {
    constexpr std::size_t deeper_than_followed = 70;
    Editor editor;
    std::string command(deeper_than_followed, '(');

    command += "true";
    command.append(deeper_than_followed, ')');
    editor.write(command);
    require(editor.press({.key = Key::enter}) == Outcome::run, "a command nested past the lexer's depth runs");
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

    // A bidi or zero-width character takes the cells of a mark naming it, in a run of its own the
    // view draws as that mark: what runs is what shows.
    const std::string_view trojan = "echo a\u202Eb\u200Bc";
    const auto marked = layout({.text = trojan, .styles = styled(trojan).view()}, {.cursor = trojan.size(), .anchor = trojan.size()}, 80);
    const auto hidden = std::ranges::count_if(marked.runs, [](const Run& run) {
      return run.style == Style::hidden;
    });
    telar::ds::String<Memory> marks{arena.memory};

    hiddenMarks("\u202E\u200B", marks);
    require(hidden == 2 && marked.caret_column == Layout::indent + 6 + (2 * hidden_mark_columns) + 2, "each takes a mark's cells, in a run of its own");
    require(marks.view() == "⟨U+202E⟩⟨U+200B⟩", "the mark names the character");

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
  const telar::testing::Case case_vim_fixes{"prompt_editor.vim_fixes", vimFixes};
  const telar::testing::Case case_emacs_goal_column{"prompt_editor.emacs_goal_column", emacsGoalColumn};
  const telar::testing::Case case_emacs_kills_accumulate{"prompt_editor.emacs_kills_accumulate", emacsKillsAccumulate};
  const telar::testing::Case case_undo_keeps_changes{"prompt_editor.undo_keeps_changes", undoKeepsChanges};
  const telar::testing::Case case_memory_returns{"prompt_editor.memory_returns", memoryReturns};
  const telar::testing::Case case_layout_and_styles{"prompt_editor.layout_and_styles", layoutAndStyles};
  const telar::testing::Case case_routing{"prompt_editor.routing", routing};
  const telar::testing::Case case_history_crosses_long_commands{"prompt_editor.history_crosses_long_commands", historyCrossesLongCommands};
  const telar::testing::Case case_vim_commands{"prompt_editor.vim_commands", vimCommands};
  const telar::testing::Case case_emacs_undoes_words{"prompt_editor.emacs_undoes_words", emacsUndoesWords};
  const telar::testing::Case case_invalid_bytes_are_characters{"prompt_editor.invalid_bytes_are_characters", invalidBytesAreCharacters};
  const telar::testing::Case case_deep_commands_run{"prompt_editor.deep_commands_run", deepCommandsRun};
  const telar::testing::Case case_answer_follows_its_first_key{"prompt_editor.answer_follows_its_first_key", answerFollowsItsFirstKey};
  const telar::testing::Case case_text_model{"prompt_editor.text_model", textModel};
  const telar::testing::Case case_emacs{"prompt_editor.emacs", emacs};
  const telar::testing::Case case_vim_basics{"prompt_editor.vim_basics", vimBasics};
  const telar::testing::Case case_vim_operators{"prompt_editor.vim_operators", vimOperators};
  const telar::testing::Case case_vim_objects{"prompt_editor.vim_objects", vimObjects};
  const telar::testing::Case case_vim_lines{"prompt_editor.vim_lines", vimLines};
  const telar::testing::Case case_vim_visual{"prompt_editor.vim_visual", vimVisual};

}
