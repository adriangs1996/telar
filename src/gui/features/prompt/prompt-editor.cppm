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
    // Not a key this keymap uses; the owner may run telar's own binding for it.
    unhandled,
  };

  class Editor {
  public:
    // The text, its registers and its recorded keys live in `memory`, region `a`.
    explicit Editor(tbc::view<Memory&, tbc::lt::a> memory, Keymap keymap = Keymap::emacs);

    Text& textMut() noexcept;

    [[nodiscard]] const Text& text() const noexcept;

    [[nodiscard]] Keymap keymap() const noexcept;

    void setKeymap(Keymap keymap) noexcept;

    [[nodiscard]] Mode mode() const noexcept;

    // An operator or count is waiting for the rest of the command.
    [[nodiscard]] bool pending() const noexcept;

    // The editor keeps the clipboard, which may borrow what lives in region `a`.
    void setClipboard(tbc::view<Clipboard, tbc::lt::a> clipboard);

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
      tbc::view<KeyPress, tbc::lt::a> key;
      tbc::view<ds::String<Memory>, tbc::lt::a> text;

      // The copy lives in the text's memory, region `a`, with the key it was recorded for.
      [[nodiscard]] tbc::view<Recorded, tbc::lt::a> clone() const {
        return {key, text.clone()};
      }
    };

    // The allocator the editor's texts come from.
    [[nodiscard]] Memory& memory() const noexcept;

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

    // ---- vim -------------------------------------------------------------------------------

    void reset() noexcept;

    void enterNormal();

    void enterInsert(std::size_t offset);

    // In normal mode the cursor sits on a character, never on a line's end, unless it is empty.
    void clampNormal() noexcept;

    [[nodiscard]] std::size_t count() const noexcept;

    Request normal(const KeyPress& key);

    Request normalControl(char32_t character);

    [[nodiscard]] ds::Option<Motion> motionFor(char32_t character) const noexcept;

    static char reversed(char kind) noexcept;

    [[nodiscard]] std::size_t firstNonBlank(std::size_t line) const noexcept;

    [[nodiscard]] std::size_t lineAt(std::size_t index) const noexcept;

    [[nodiscard]] Motion findMotion(char kind, char32_t target, std::size_t repeat, bool repeated = false) const;

    [[nodiscard]] Motion matchingBracket(std::size_t cursor) const noexcept;

    // A motion moves the cursor, or with an operator pending, ends the range it acts on.
    Request applyMotion(Motion motion);

    Request applyTextObject(char32_t character);

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> textObject(char32_t character, bool inner) const;

    [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> bracketObject(char open, char close, bool inner) const;

    // Applies the pending operator to [start, end), whole lines when `linewise`.
    void operate(std::size_t start, std::size_t end, bool linewise);

    // Shifts every line in [start, end) by two spaces, as `>` and `<` do.
    void indent(std::size_t start, std::size_t end, bool right);

    void changeCase(std::size_t start, std::size_t end, char action);

    void store(std::string_view text, bool linewise);

    struct Register {
      tbc::view<ds::String<Memory>, tbc::lt::a> text;
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

    Request visualCommand(char32_t character);

    // ---- dot repeat ------------------------------------------------------------------------

    void startRecording(const KeyPress& key);

    void record(const KeyPress& key);

    void finishRecording() noexcept;

    void repeat();

    static std::size_t encode(char32_t value, ds::Array<char, 4>& output) noexcept;

    tbc::view<Text, tbc::lt::a> text_;
    Keymap keymap_;
    Mode mode_ = Mode::insert;
    tbc::view<Clipboard, tbc::lt::a> clipboard_;
    tbc::view<ds::String<Memory>, tbc::lt::a> kill_ring_;
    tbc::view<ds::String<Memory>, tbc::lt::a> pasted_;
    tbc::view<Register, tbc::lt::a> unnamed_;
    // vim's named registers, a to z.
    tbc::view<ds::Vec<Register, Memory>, tbc::lt::a> registers_;
    tbc::view<ds::Vec<Recorded, Memory>, tbc::lt::a> recorded_;
    tbc::view<ds::Vec<Recorded, Memory>, tbc::lt::a> last_change_;
    ds::Option<std::size_t> goal_column_;
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
