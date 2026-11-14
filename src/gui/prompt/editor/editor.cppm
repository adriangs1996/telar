module;
#include <cstddef>
#include <cstdint>

export module telar.gui.prompt.editor;

import std;

export import telar.gui.prompt.text;

// The command editor's keyboard model, apart from Qt so it is testable: a key in, an edit and
// maybe a request out. Two keymaps, readline's emacs bindings and vim's modal editing.
export namespace telar::gui::prompt {

  enum class Key : std::uint8_t {
    character,
    enter,
    backspace,
    delete_forward,
    left,
    right,
    up,
    down,
    home,
    end,
    tab,
    backtab,
    escape,
  };

  struct Modifiers {
    bool control = false;
    bool alt = false;
    bool shift = false;

    bool operator==(const Modifiers&) const = default;
  };

  // One key press. `text` holds what a character key types, UTF-8; `character` the code point
  // a binding matches, lower case for letters with control.
  struct KeyPress {
    Key key = Key::character;
    char32_t character = 0;
    Modifiers modifiers{};
    std::string_view text{};
  };

  // What the editor asks of its owner after a key.
  enum class Request : std::uint8_t {
    none,
    // Enter: the owner runs the command if the shell would, or calls `newline`.
    submit,
    history_previous,
    history_next,
    history_search,
    complete,
    // Ctrl-C: the owner drops the line, as the shell would.
    cancel,
    // Ctrl-D on an empty line.
    end_of_file,
    clear_screen,
    // Not a key this keymap uses; the owner may run telar's own binding for it.
    unhandled,
  };

  // What a key bound in `client.prompt.bindings` does. The names, in this order, are
  // `prompt_action_names` in telar-config, which validates them.
  enum class Action : std::uint8_t {
    submit,
    newline,
    cancel,
    complete,
    accept_suggestion,
    history_previous,
    history_next,
    history_search,
    line_start,
    line_end,
    char_left,
    char_right,
    word_left,
    word_right,
    delete_char,
    backspace,
    kill_line,
    kill_to_start,
    kill_word,
    kill_word_back,
    yank,
    undo,
    redo,
    transpose,
    clear_screen,
    normal_mode,
    insert_mode,
  };

  enum class Keymap : std::uint8_t {
    emacs,
    vim,
  };

  enum class Mode : std::uint8_t {
    insert,
    normal,
    visual,
    visual_line,
  };

  // The system clipboard behind vim's "+ and "* registers.
  struct Clipboard {
    std::function<std::string()> read;
    std::function<void(std::string_view)> write;
  };

  class Editor {
  public:
    explicit Editor(Keymap keymap = Keymap::emacs);

    Text& text() noexcept;

    const Text& text() const noexcept;

    Keymap keymap() const noexcept;

    void setKeymap(Keymap keymap) noexcept;

    Mode mode() const noexcept;

    // An operator or count is waiting for the rest of the command.
    bool pending() const noexcept;

    void setClipboard(Clipboard clipboard);

    // Starts a new line, back in insert mode.
    void clear() noexcept;

    void newline();

    // Text an input method committed or the user pasted.
    void insertText(std::string_view text);

    // A bound action, whatever the keymap: the same edits the default keys make.
    Request perform(Action action);

    Request press(const KeyPress& key);

  private:
    enum class Pending : std::uint8_t {
      none,
      find,
      replace,
      g,
      text_object,
    };

    struct Motion {
      std::size_t target = 0;
      bool inclusive = false;
      bool linewise = false;
      bool valid = true;
    };

    struct Recorded {
      KeyPress key;
      std::string text;
    };

    // ---- shared editing --------------------------------------------------------------------

    Request insert(const KeyPress& key);

    // readline's control bindings, which vim's insert mode shares for the common ones.
    Request control(char32_t character);

    Request meta(char32_t character);

    void move(std::size_t offset, bool extend = false) noexcept;

    // Up and down move between lines, and past the first or last one to the history.
    Request vertical(int direction, bool extend);

    void kill(std::size_t start, std::size_t end);

    void killBackward(std::size_t start);

    void transpose();

    // ---- word boundaries -------------------------------------------------------------------

    bool blank(std::size_t offset) const noexcept;

    CharacterClass kind(std::size_t offset, bool big) const noexcept;

    // The start of the word before the offset (readline's backward-word and vim's b).
    std::size_t wordStart(std::size_t offset, bool big) const noexcept;

    std::size_t bigWordStart(std::size_t offset) const noexcept;

    // readline's forward-word: past the next word.
    std::size_t wordEnd(std::size_t offset) const noexcept;

    // vim's w: the start of the next word.
    std::size_t nextWord(std::size_t offset, bool big) const noexcept;

    // The last character of the run of one class the offset is in.
    std::size_t runEnd(std::size_t offset, bool big) const noexcept;

    // vim's e: the last character of the current or next word.
    std::size_t endOfWord(std::size_t offset, bool big) const noexcept;

    // ---- vim -------------------------------------------------------------------------------

    void reset() noexcept;

    void enterNormal();

    void enterInsert(std::size_t offset);

    // In normal mode the cursor sits on a character, never on a line's end, unless it is empty.
    void clampNormal() noexcept;

    std::size_t count() const noexcept;

    Request normal(const KeyPress& key);

    Request normalControl(char32_t character);

    std::optional<Motion> motionFor(char32_t character) const noexcept;

    static char reversed(char kind) noexcept;

    std::size_t firstNonBlank(std::size_t line) const noexcept;

    std::size_t lineAt(std::size_t index) const noexcept;

    Motion findMotion(char kind, char32_t target, std::size_t repeat, bool repeated = false) const;

    Motion matchingBracket(std::size_t cursor) const noexcept;

    // A motion moves the cursor, or with an operator pending, ends the range it acts on.
    Request applyMotion(Motion motion);

    Request applyTextObject(char32_t character);

    std::optional<std::pair<std::size_t, std::size_t>> textObject(char32_t character, bool inner) const;

    std::optional<std::pair<std::size_t, std::size_t>> bracketObject(char open, char close, bool inner) const;

    // Applies the pending operator to [start, end), whole lines when `linewise`.
    void operate(std::size_t start, std::size_t end, bool linewise);

    // Shifts every line in [start, end) by two spaces, as `>` and `<` do.
    void indent(std::size_t start, std::size_t end, bool right);

    void changeCase(std::size_t start, std::size_t end, char action);

    void store(std::string_view text, bool linewise);

    struct Register {
      std::string text;
      bool linewise = false;
    };

    Register load() const;

    void put(bool before);

    void replaceCharacters(std::string_view typed);

    Request command(char32_t character, const KeyPress& key);

    Request visualCommand(char32_t character);

    // ---- dot repeat ------------------------------------------------------------------------

    void startRecording(const KeyPress& key);

    void record(const KeyPress& key);

    void finishRecording() noexcept;

    void repeat();

    static std::size_t encode(char32_t value, std::array<char, 4>& output) noexcept;

    Text text_;
    Keymap keymap_;
    Mode mode_ = Mode::insert;
    Clipboard clipboard_;
    std::string kill_ring_;
    Register unnamed_;
    std::array<Register, 26> registers_;
    std::vector<Recorded> recorded_;
    std::vector<Recorded> last_change_;
    std::optional<std::size_t> goal_column_;
    std::pair<char, char32_t> last_find_{'f', 0};
    std::size_t count_ = 0;
    std::size_t operator_count_ = 0;
    unsigned replaying_ = 0;
    Pending pending_ = Pending::none;
    char operator_ = 0;
    char register_ = '"';
    char find_kind_ = 'f';
    bool text_object_inner_ = true;
    bool register_pending_ = false;
    bool recording_ = false;
  };

}
