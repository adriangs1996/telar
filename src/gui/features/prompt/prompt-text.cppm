// The text of the command being edited: UTF-8 bytes, a cursor and an anchor that are always on
// code point boundaries, and grouped undo. Every edit goes through `replace`, so undo, the
// revision and the bounds hold for all of them. Nothing here is exported: only the feature's own
// units name it, through a pane's line.
export module telar.gui.features.prompt:text;

import std;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::prompt {

  class Text {
  public:
    // A pasted file must not grow the editor without bound; the shell's own line editor has
    // limits of the same order.
    static constexpr std::size_t capacity = std::size_t{256} * 1024;
    static constexpr std::size_t undo_capacity = 256;

    // The text and its undo history live in `memory`.
    // The text and its history live in `memory`, region `a`.
    explicit Text(tbc::mut_a<Memory> memory);

    [[nodiscard]] std::string_view view() const noexcept;

    [[nodiscard]] std::size_t size() const noexcept;

    [[nodiscard]] bool empty() const noexcept;

    [[nodiscard]] std::size_t cursor() const noexcept;

    // The other end of the selection; equal to the cursor without one.
    [[nodiscard]] std::size_t anchor() const noexcept;

    [[nodiscard]] bool selecting() const noexcept;

    [[nodiscard]] std::size_t selectionStart() const noexcept;

    [[nodiscard]] std::size_t selectionEnd() const noexcept;

    // Counts every change to the text, so views redraw only what changed.
    [[nodiscard]] std::uint64_t revision() const noexcept;

    void moveTo(std::size_t offset, bool extend = false) noexcept;

    void select(std::size_t anchor, std::size_t cursor) noexcept;

    // Replaces [start, end) with `text` and leaves the cursor after it. Consecutive typing or
    // deleting joins one undo step, so undo removes a word typed, not a letter. Returns false
    // when the result would exceed the capacity, leaving everything as it was.
    bool replace(std::size_t start, std::size_t end, std::string_view text, bool typing = false);

    bool insert(std::string_view text, bool typing = false);

    void assign(std::string_view text);

    void clear() noexcept;

    bool undo();

    bool redo();

    // Ends the current undo group, as moving the cursor does.
    void seal() noexcept;

    // Code point navigation.
    [[nodiscard]] std::size_t next(std::size_t offset) const noexcept;

    [[nodiscard]] std::size_t previous(std::size_t offset) const noexcept;

    [[nodiscard]] std::size_t lineStart(std::size_t offset) const noexcept;

    [[nodiscard]] std::size_t lineEnd(std::size_t offset) const noexcept;

    [[nodiscard]] std::size_t lineCount() const noexcept;

    [[nodiscard]] std::size_t lineOf(std::size_t offset) const noexcept;

    // The code points between the line start and the offset, for keeping a column across lines.
    [[nodiscard]] std::size_t column(std::size_t offset) const noexcept;

    struct LineColumn {
      std::size_t line_start = 0;
      std::size_t column = 0;
    };

    // The offset `column` code points into the line, or the line's end when it is shorter.
    [[nodiscard]] std::size_t atColumn(LineColumn place) const noexcept;

    static bool continuation(char byte) noexcept;

  private:
    enum class Group : std::uint8_t {
      none,
      insert,
      erase,
    };

    struct Snapshot {
      tbc::val_a<ds::String<Memory>> bytes;
      std::size_t cursor;
    };

    [[nodiscard]] std::size_t boundary(std::size_t offset) const noexcept;

    void record();

    // Restores the last snapshot of the undo history, or of the redo history when not `back`, and
    // keeps the current text in the other.
    bool travel(bool back);

    tbc::val_a<ds::String<Memory>> bytes_;
    tbc::val_a<ds::Vec<Snapshot, Memory>> undo_;
    tbc::val_a<ds::Vec<Snapshot, Memory>> redo_;
    std::size_t cursor_ = 0;
    std::size_t anchor_ = 0;
    std::uint64_t revision_ = 0;
    Group group_ = Group::none;
  };

  // Word classes as vim and readline use them: letters, digits and underscore form words,
  // other non-blank characters form their own, and blanks separate both.
  enum class CharacterClass : std::uint8_t {
    blank,
    word,
    punctuation,
  };

  CharacterClass classify(char byte) noexcept;

}
