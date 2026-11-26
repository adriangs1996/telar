// The command editor's keyboard model, apart from Qt so it is testable: a key in, an edit and
// maybe a request out. Two keymaps, readline's emacs bindings and vim's modal editing. Nothing
// here is exported: only the feature's own units name it, through a pane's line.
export module telar.gui.features.prompt:editor;

import std;

import :keys;
import :text;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.tbc;

namespace telar::gui::features::prompt {

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
    // Alt-. and Alt-_: the owner writes the last argument of a command before, an older one
    // each time the key comes again.
    last_argument,
    // Not a key this keymap uses; the owner may run telar's own binding for it.
    unhandled,
  };

  class Editor {
  public:
    // The text, its registers and its recorded keys live in `memory`, region `a`.
    explicit Editor(tbc::mut_a<Memory> memory, Keymap keymap = Keymap::emacs);

    Text& textMut() noexcept;

    [[nodiscard]] const Text& text() const noexcept;

    [[nodiscard]] Keymap keymap() const noexcept;

    void setKeymap(Keymap keymap) noexcept;

    [[nodiscard]] Mode mode() const noexcept;

    // What a visual mode takes, and highlights: from one end's character through the other's for v,

    // the lines they are on for V; none outside them.

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> visualRange() const noexcept;

    // An operator or count is waiting for the rest of the command.
    [[nodiscard]] bool pending() const noexcept;

    // The editor keeps the clipboard, which may borrow what lives in region `a`.
    void setClipboard(tbc::val_a<Clipboard> clipboard);

    // Starts a new line, back in insert mode.
    void clear() noexcept;

    // Ctrl-C: the line goes, as the shell drops it, but as a kill and an undo step: Ctrl-Y puts
    // it back, and so does undo.
    void cancel();

    // The command goes on on a new line, after the text outside vim's insert mode.
    void newline();

    // The caret after the text, as a command recalled leaves it: on its last character in vim's
    // normal mode, where it sits on one.
    void placeAtEnd() noexcept;

    // Text an input method committed or the user pasted.
    void insertText(std::string_view text);

    // A bound action, whatever the keymap: the same edits the default keys make.
    Request perform(Action action);

    Request press(const KeyPress& key);

  private:
    // perform's own work, inside the goal column's bookkeeping.
    Request performAction(Action action);

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
      tbc::val_a<KeyPress> key;
      tbc::val_a<ds::String<Memory>> text;

      // The copy lives in the text's memory, region `a`, with the key it was recorded for.
      [[nodiscard]] tbc::val_a<Recorded> clone() const;
    };

    // The allocator the editor's texts come from.
    [[nodiscard]] Memory& memory() const noexcept;

    // ---- shared editing --------------------------------------------------------------------

    // The key to the keymap and mode it belongs to, without recording it or repeating.
    Request dispatch(const KeyPress& key);

    Request insert(const KeyPress& key);

    // Backspace: the selection, the word before the cursor when `word`, or the character.
    void eraseBackward(bool word);

    // Escape in insert mode: vim's normal mode, or the selection dropped.
    Request escapeInsert();

    // readline's control bindings, which vim's insert mode shares for the common ones.
    Request control(char32_t character);

    Request meta(char32_t character);
    // Alt-U, Alt-L and Alt-C: the word from the cursor in capitals, small letters, or with its
    // first letter a capital, the cursor after it.
    void changeCase(char32_t how);

    void move(std::size_t offset, bool extend = false) noexcept;

    // Up and down move between lines, and past the first or last one to the history.
    Request vertical(int direction, bool extend);

    void kill(std::size_t start, std::size_t end);

    void killBackward(std::size_t start);

    void transpose();

    // ---- word boundaries -------------------------------------------------------------------

    [[nodiscard]] bool blank(std::size_t offset) const noexcept;

    [[nodiscard]] CharacterClass kind(std::size_t offset, bool big) const noexcept;

    // The start of the word before the offset (readline's backward-word and vim's b).
    [[nodiscard]] std::size_t wordStart(std::size_t offset, bool big) const noexcept;

    [[nodiscard]] std::size_t bigWordStart(std::size_t offset) const noexcept;

    // readline's forward-word: past the next word.
    [[nodiscard]] std::size_t wordEnd(std::size_t offset) const noexcept;

    // vim's w: the start of the next word.
    [[nodiscard]] std::size_t nextWord(std::size_t offset, bool big) const noexcept;

    // The last character of the run of one class the offset is in.
    [[nodiscard]] std::size_t runEnd(std::size_t offset, bool big) const noexcept;

    // vim's e: the last character of the current or next word.
    [[nodiscard]] std::size_t endOfWord(std::size_t offset, bool big) const noexcept;
    // The end of the word before the one at `offset`, as vim's ge goes back to it.
    [[nodiscard]] std::size_t wordEndBackward(std::size_t offset, bool big) const noexcept;

    // ---- vim -------------------------------------------------------------------------------

    void reset() noexcept;

    void enterNormal();

    void enterInsert(std::size_t offset);

    // In normal mode the cursor sits on a character, never on a line's end, unless it is empty.
    void clampNormal() noexcept;

    // A count's digits, and the product of a count and an operator's: past four digits, a
    // count only makes vim slower.
    static constexpr std::size_t maximum_count = 9999;

    // The count before the command times the operator's, at most maximum_count.
    [[nodiscard]] std::size_t count() const noexcept;

    Request normal(const KeyPress& key);

    // The key that completes a register, a replace, a find, a g command or a text object.
    ds::Option<Request> pendingKey(char32_t character, const KeyPress& key);

    Request afterG(char32_t character);

    // Adds `character` to the count when it is one of its digits.
    bool countDigit(char32_t character) noexcept;

    Request normalKey(char32_t character, const KeyPress& key);

    Request normalControl(char32_t character);

    [[nodiscard]] ds::Option<Motion> motionFor(char32_t character) const;

    [[nodiscard]] Motion wordMotion(bool big) const noexcept;

    [[nodiscard]] Motion lineEndMotion() const noexcept;

    // j and k, keeping the cursor's column.
    [[nodiscard]] Motion lineMotion(bool down) const noexcept;

    static char reversed(char kind) noexcept;

    [[nodiscard]] std::size_t firstNonBlank(std::size_t line) const noexcept;

    [[nodiscard]] std::size_t lineAt(std::size_t index) const noexcept;

    // f, F, t or T for a character.
    struct Find {
      char kind = 'f';
      char32_t target = 0;
    };

    [[nodiscard]] Motion findMotion(Find find, std::size_t repeat, bool repeated = false) const;

    // The next `needle` after `position` and before the line's `end`, past the one right after
    // `position` when `skip`.
    [[nodiscard]] ds::Option<std::size_t> findAfter(std::size_t position, std::string_view needle, bool skip, std::size_t end) const;

    // The previous `needle` before `position` and from the line's `start`, past the one right
    // before `position` when `skip`.
    [[nodiscard]] ds::Option<std::size_t> findBefore(std::size_t position, std::string_view needle, bool skip, std::size_t start) const;

    [[nodiscard]] Motion matchingBracket(std::size_t cursor) const noexcept;

    // A motion moves the cursor, or with an operator pending, ends the range it acts on.
    Request applyMotion(Motion motion);

    Request applyTextObject(char32_t character);

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> textObject(char32_t character, bool inner) const;

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> wordObject(bool big, bool inner) const;

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> quoteObject(char quote, bool inner) const;

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> bracketObject(char open, char close, bool inner) const;

    // Applies the pending operator to [start, end), whole lines when `linewise`.
    void operate(std::size_t start, std::size_t end, bool linewise);

    // Shifts every line in [start, end) by two spaces, as `>` and `<` do.
    void indent(std::size_t start, std::size_t end, bool right);

    void changeCase(std::size_t start, std::size_t end, char action);

    // What a delete, change or yank takes goes in the register named, at the end of its text for
    // an uppercase name, and in the unnamed one.
    void store(std::string_view text, bool linewise);

    // The index of register `name` among a to z, whatever its case.
    [[nodiscard]] static ds::Option<std::size_t> namedRegister(char name) noexcept;

    struct Register {
      tbc::val_a<ds::String<Memory>> text;
      bool linewise = false;
    };

    // The text a put inserts: the register's, or the clipboard's read into `pasted_`.
    struct Loaded {
      std::string_view text;
      bool linewise = false;
    };

    Loaded load();

    void put(bool before);

    void replaceCharacters(std::string_view typed);

    Request command(char32_t character, const KeyPress& key);

    // The key after an operator: the same operator again takes whole lines.
    void secondOperator(char32_t character);

    // Where i, a, I and A start inserting.
    [[nodiscard]] std::size_t insertPosition(char32_t character) const noexcept;

    // The pending operator over the cursor's line and the count's lines after it.
    void operateOnLines();

    void openLine(bool above);

    // x, or X when `backward`: the count's characters on the cursor's line.
    void deleteCharacters(bool backward);

    // S, C, D and Y.
    void operateToLineEnd(char32_t character, const KeyPress& key);

    void toggleCase();

    void joinLines();

    void undoChanges();

    Request visualCommand(char32_t character);
    Request visualPut(std::size_t start, std::size_t end, bool lines);

    // ---- dot repeat ------------------------------------------------------------------------

    void startRecording(const KeyPress& key);

    void record(const KeyPress& key);

    void finishRecording();

    void repeat();

    // A key that starts an operator, g for the case ones: a count given to a dot replaces the
    // one typed after it.
    [[nodiscard]] static bool operatorKey(const KeyPress& key) noexcept;

    // The keys of a recorded change that hold its counts, which a count given to a dot replaces:
    // [0, first) before it, and the operator's, [operator_begin, operator_end).
    struct Counts {
      std::size_t first = 0;
      std::size_t operator_begin = 0;
      std::size_t operator_end = 0;
    };

    [[nodiscard]] static Counts countsOf(std::span<const Recorded> changes) noexcept;

    static std::size_t encode(char32_t value, ds::Array<char, 4>& output) noexcept;

    tbc::val_a<Text> text_;
    Keymap keymap_;
    Mode mode_ = Mode::insert;
    tbc::val_a<Clipboard> clipboard_;
    tbc::val_a<ds::String<Memory>> kill_ring_;
    tbc::val_a<ds::String<Memory>> pasted_;
    tbc::val_a<Register> unnamed_;
    // vim's named registers, a to z.
    tbc::val_a<ds::Vec<Register, Memory>> registers_;
    tbc::val_a<ds::Vec<Recorded, Memory>> recorded_;
    tbc::val_a<ds::Vec<Recorded, Memory>> last_change_;
    ds::Option<std::size_t> goal_column_;
    // Whether the key or action being handled moved Up or Down, which keeps the goal column.
    bool vertical_ = false;
    // Whether the key being handled killed text, and whether the one before did.
    bool killing_ = false;
    bool killed_ = false;
    // Escape began a Meta key in emacs, as readline reads `Esc b` as Alt-B; Ctrl-V the next key
    // goes in as typed, a tab included.
    bool meta_pending_ = false;
    bool quoted_pending_ = false;
    Find last_find_;
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
    // A dot asked to repeat the last change, which `press` does once the key is done.
    bool repeat_requested_ = false;
  };

}
