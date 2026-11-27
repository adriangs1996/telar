export module telar.base.text.pattern;

import std;
import telar.base.ds;

namespace telar::runtime {

  // The threads of a search that wait for a character, in the order the match prefers them, and
  // the index that tells whether an instruction is among them. A search holds two: those at this
  // character and those at the next.
  struct PatternThreads {
    static constexpr std::size_t capacity = 2048;

    ds::Array<std::uint16_t, capacity> programs{};
    ds::Array<std::uint32_t, capacity> starts{};
    ds::Array<std::uint16_t, capacity> index{};
    std::size_t count = 0;

    [[nodiscard]] bool holds(std::uint16_t program) const noexcept;
    void add(std::uint16_t program, std::uint32_t start) noexcept;
  };

  // The instructions a thread's jumps lead to, still to follow.
  using PatternStack = ds::Array<std::uint16_t, (2 * PatternThreads::capacity) + 2>;

}

// Interface: telar_base/text/pattern.cppm
export namespace telar::runtime {

  // How a pattern reads its text.
  struct PatternOptions {
    // A regular expression; otherwise the text is looked for as it is.
    bool regex = false;
    // Letters match in either case, as the history folds them: Unicode's simple case folding, in
    // the pattern and the text alike.
    bool ignore_case = false;
  };

  // Where a match lies in the text it was found in: its first byte and the byte past its last.
  struct PatternMatch {
    std::size_t begin = 0;
    std::size_t end = 0;

    bool operator==(const PatternMatch&) const = default;
  };

  // A regular expression that does not compile; what() says why.
  class PatternError final : public std::exception {
  public:
    explicit PatternError(const char* reason) noexcept;

    [[nodiscard]] const char* what() const noexcept override;

  private:
    const char* reason_;
  };

  class PatternScratch;

  // A pattern compiled once and looked for in many texts. A regular expression runs as a Pike
  // machine over the characters of the text: the time a text takes grows with the text and the
  // program, never with how the two interact, so no pattern a person, a peer or a configuration
  // gives and no line a program prints can make it backtrack. A search allocates nothing past
  // the first of its thread, and threads may look for one pattern at once.
  //
  // A regular expression has literals and `\` escapes (`\t` `\n` `\r` and punctuation), `.`,
  // classes such as `[a-z_]` and `[^0-9]` of any characters, `\d` `\w` `\s` and their negations
  // (ASCII), groups `(...)` and `(?:...)`, alternation `|`, the quantifiers `*` `+` `?` `{m}`
  // `{m,}` `{m,n}` (each lazy with a `?` after it), and the assertions `^` `$` (at a line's ends)
  // `\b` `\B`. `.` and every class take a whole UTF-8 character; a byte that starts none is a
  // character of its own, which only `.` and a negated class take. The match is the leftmost,
  // and of those the one a backtracking engine would find first.
  class Pattern {
  public:
    static constexpr std::size_t maximum_pattern_bytes = 1024;
    static constexpr std::size_t maximum_instructions = PatternThreads::capacity;
    static constexpr std::size_t maximum_classes = 64;
    static constexpr std::size_t maximum_class_ranges = 512;
    static constexpr std::size_t maximum_repeat = 100;
    static constexpr std::size_t maximum_depth = 32;

    // A pattern that matches nothing, until one is assigned.
    Pattern() noexcept;

    // Compiles `pattern`, at most `maximum_pattern_bytes`. A regular expression that does not
    // compile, or compiles past the bounds above, throws PatternError.
    Pattern(std::string_view pattern, PatternOptions options);

    Pattern(const Pattern& other);
    Pattern& operator=(const Pattern& other);
    Pattern(Pattern&& other) noexcept;
    Pattern& operator=(Pattern&& other) noexcept;
    ~Pattern();

    // The first match in `text` that starts at or after byte `from`, run in buffers of the
    // calling thread's own.
    [[nodiscard]] ds::Option<PatternMatch> find(std::string_view text, std::size_t from = 0) const noexcept;

    // The same, run in `scratch`, which the caller keeps for its searches.
    [[nodiscard]] ds::Option<PatternMatch> find(std::string_view text, std::size_t from, PatternScratch& scratch) const noexcept;

    // Whether `text` holds a match.
    [[nodiscard]] bool matches(std::string_view text) const noexcept;

    // Whether no pattern was compiled into it.
    [[nodiscard]] bool empty() const noexcept;

    [[nodiscard]] const PatternOptions& options() const noexcept;

  private:
    friend class PatternCompiler;
    friend class PatternScratch;

    enum class Op : std::uint8_t {
      character,
      any,
      set,
      split,
      jump,
      line_start,
      line_end,
      boundary,
      not_boundary,
      match,
    };

    // `value` is a character or a set; a split tries `x` first, then `y`; a jump goes to `x`.
    struct Instruction {
      Op op = Op::match;
      std::uint16_t x = 0;
      std::uint16_t y = 0;
      std::uint32_t value = 0;
    };

    struct Range {
      std::uint32_t first = 0;
      std::uint32_t last = 0;
    };

    struct Set {
      std::uint16_t first_range = 0;
      std::uint16_t range_count = 0;
      bool negated = false;
    };

    using ByteSet = ds::Array<std::uint64_t, 4>;

    // What a pattern compiles into, on the heap: a pattern that holds none, as the unused slots
    // of a configuration's list, costs a pointer.
    struct Program {
      ds::Array<Instruction, maximum_instructions> instructions{};
      std::size_t instruction_count = 0;
      ds::Array<Range, maximum_class_ranges> ranges{};
      ds::Array<Set, maximum_classes> sets{};
      // The literal looked for, its letters lower case when the case is ignored; none when the
      // machine runs.
      ds::Array<char, maximum_pattern_bytes> literal{};
      std::size_t literal_size = 0;
      bool literal_search = false;
      // The bytes a match can start with; any byte when it may start with every one.
      ByteSet first{};
      bool any_first = true;
    };

    [[nodiscard]] ds::Option<PatternMatch> findLiteral(std::string_view text, std::size_t from) const noexcept;
    [[nodiscard]] ds::Option<PatternMatch> findRegex(std::string_view text, std::size_t from, PatternScratch& scratch) const noexcept;
    [[nodiscard]] std::uint32_t folded(std::uint32_t character) const noexcept;
    [[nodiscard]] bool inSet(std::uint32_t index, std::uint32_t character) const noexcept;
    [[nodiscard]] bool takes(const Instruction& instruction, std::uint32_t character) const noexcept;
    // Whether an assertion holds at byte `position` of `text`.
    [[nodiscard]] static bool assertion(Op operation, std::string_view text, std::size_t position) noexcept;
    // Starts a thread at `position`, or at the first byte from it a match can start with when
    // none is under way; the position it started at, the text's end when none can.
    std::size_t begin(PatternThreads& threads, PatternStack& stack, std::string_view text, std::size_t position) const noexcept;

    // A thread: the instruction it is at, and the byte its match began at.
    struct Thread {
      std::uint16_t program = 0;
      std::uint32_t start = 0;
    };

    // Adds `thread` and every instruction its jumps reach at `position`.
    void follow(PatternThreads& threads, PatternStack& stack, Thread thread, std::string_view text, std::size_t position) const noexcept;

    // What one step of the machine over the character at `position` found.
    struct Step {
      ds::Option<PatternMatch> match;
      // A thread was under way.
      bool alive = false;
    };

    // Moves the threads of `current` past the character at `position` into `next`.
    Step step(const PatternThreads& current, PatternThreads& next, PatternStack& stack, std::string_view text, std::size_t position) const noexcept;
    // The first byte from `position` a match can start with, or the text's end.
    [[nodiscard]] std::size_t skip(std::string_view text, std::size_t position) const noexcept;

    PatternOptions options_;
    std::unique_ptr<Program> program_;
  };

  // What one search of a Pattern runs in: the threads of the machine and the jumps it follows. A
  // thread that searches keeps one and reuses it for every search, of any pattern.
  class PatternScratch {
  public:
    PatternScratch() noexcept = default;

  private:
    friend class Pattern;

    PatternThreads even_;
    PatternThreads odd_;
    PatternStack stack_{};
  };

}
