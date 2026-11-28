module;

// The lines of a command's output as a filter reads them: each a pattern matched or not, the
// rows it keeps shown, with the lines around a match, and the text they hold.
export module telar.gui.features.terminal.filter:lines;

import std;

import telar.base.text.pattern;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::gui::features::terminal::filter {

  // A run of rows shown, by stable row: from `first` up to `end`.
  struct ShownRun {
    std::uint64_t first = 0;
    std::uint64_t end = 0;

    bool operator==(const ShownRun&) const = default;
  };

  // Lines read in order, one row at a time: a line ends on a row that does not wrap into the
  // next. A line the pattern matches (or, inverted, does not) is shown, with up to `context`
  // lines before and after it. What is shown is kept as runs of rows and as text, both bounded:
  // past either bound nothing more is kept, and `truncated` says so.
  class Lines {
  public:
    static constexpr std::size_t maximum_context = 20;
    static constexpr std::size_t maximum_runs = 65'536;
    static constexpr std::size_t maximum_text_bytes = std::size_t{4} * 1024 * 1024;
    // The part of a line that is matched and kept; a longer one is cut there.
    static constexpr std::size_t maximum_line_bytes = std::size_t{64} * 1024;

    explicit Lines(Memory& memory);

    // Starts over: no line read.
    void reset(std::size_t context, bool invert) noexcept;

    // Starts where `other` stands, with nothing of its own shown: the line it has half read and
    // the lines it holds back for a match's context go on here.
    void follow(const Lines& other);

    // Row `row` holds `text`; `wraps` when its line goes on in the next row.
    void feed(runtime::Pattern& pattern, std::uint64_t row, std::string_view text, bool wraps);

    [[nodiscard]] std::span<const ShownRun> runs() const noexcept;
    [[nodiscard]] std::string_view text() const noexcept;
    [[nodiscard]] std::size_t matches() const noexcept;
    [[nodiscard]] bool truncated() const noexcept;

  private:
    // A line held back as a possible match's context: its rows and where its text is.
    struct HeldLine {
      std::uint64_t first = 0;
      std::uint64_t end = 0;
      std::size_t offset = 0;
      std::size_t length = 0;
    };

    // The lines before the next match, oldest first, their text one after another.
    struct Held {
      explicit Held(Memory& memory);

      ds::Array<HeldLine, maximum_context> lines{};
      std::size_t count = 0;
      ds::String<Memory> text;
    };

    // What is shown: its rows, its text, the lines that matched, and whether a bound cut it.
    struct Shown {
      explicit Shown(Memory& memory);

      ds::Vec<ShownRun, Memory> runs;
      ds::String<Memory> text;
      std::size_t matches = 0;
      bool truncated = false;
    };

    void finish(runtime::Pattern& pattern);
    static void show(Shown& shown, std::uint64_t first, std::uint64_t end, std::string_view line);
    static void hold(Held& held, std::size_t context, std::uint64_t first, std::uint64_t end, std::string_view line);
    static void release(Held& held, Shown& shown);

    std::size_t context_ = 0;
    bool invert_ = false;
    // The line being read: its first row, the row past its last, and its text so far.
    std::uint64_t line_first_ = 0;
    std::uint64_t line_end_ = 0;
    bool reading_ = false;
    ds::String<Memory> line_;
    Held held_;
    // The lines a match's context still shows after it.
    std::size_t after_ = 0;
    Shown shown_;
  };

}
