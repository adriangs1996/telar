// The history's matcher: a query parsed once into a pattern, then matched against each command
// with fzf's FuzzyMatchV2 and its extended search syntax, in the scratch of a caller's arena, so
// that no call allocates.
//
//   HistoryPattern pattern{"git 'push !wip", HistoryMatchMode::fuzzy};
//   auto arena = std::make_unique<HistoryMatchArena>(); // once per thread
//
//   for (const auto command : commands) {
//     if (const auto score = historyMatch(pattern, command, *arena)) { ... }
//   }
//
// A higher score is a better match; among equal scores the caller's order (recency) decides, as
// fzf's history scheme does. historyRank (:rank) folds the score and a command's priors into the
// key the results sort by.
export module telar.base.history:match;

import std;
import telar.base.ds;

export namespace telar::runtime {

  // How the terms of a query match. regex is the runtime's, with its own engine.
  //  - fuzzy: fzf's: each term a subsequence, scored by FuzzyMatchV2, with the extended syntax.
  //  - substring: hstr's keywords: each term a substring, in any order, a command that starts
  //    with one ranked above every command that does not; `'term` is fuzzy, the rest of the
  //    syntax as in fuzzy.
  //  - prefix: the whole query, spaces and all, starts the command (leading spaces aside).
  //  - exact: the whole query, spaces and all, is a substring of the command.
  enum class HistoryMatchMode : std::uint8_t {
    fuzzy,
    substring,
    prefix,
    exact,
  };

  // What one term asks of a command, from its syntax:
  //   term     fuzzy (exact in substring mode)       'term   exact (fuzzy in substring mode)
  //   'term'   exact, on word boundaries             ^term   prefix
  //   term$    suffix                                ^term$  equal, the whole command
  //   !term    the command does not contain it (exact; !'term fuzzy, !^term, !term$ as above)
  enum class HistoryTermKind : std::uint8_t {
    fuzzy,
    exact,
    exact_boundary,
    prefix,
    suffix,
    equal,
  };

  // One term of a pattern. Its characters are already as it compares them: folded unless it is
  // case sensitive, without diacritics when it normalizes.
  struct HistoryTerm {
    HistoryTermKind kind = HistoryTermKind::fuzzy;
    // The command must not match it.
    bool inverse = false;
    // It holds a capital, so it matches case for case (smart case).
    bool case_sensitive = false;
    // It holds no latin diacritic, so it matches a command's letters without theirs.
    bool normalize = false;
    // It and the next term are alternatives (`a | b`); terms without it are all required.
    bool or_next = false;
    // Substring mode's plain term: a command it starts ranks first.
    bool ranks_prefix = false;
    std::uint16_t offset = 0;
    std::uint16_t length = 0;
  };

  // A query parsed once, for every command it is matched against. Space separates terms that
  // must all match, `|` between two terms makes them alternatives, `\ ` is a space inside a
  // term. A term that holds a capital is case sensitive; one that holds no latin diacritic
  // matches the letters of a command without theirs. Holds what it parsed inline: a query
  // past max_characters or max_terms is never typed, and what exceeds them is left out.
  class HistoryPattern {
  public:
    static constexpr std::size_t max_characters = 1024;
    static constexpr std::size_t max_terms = 64;

    HistoryPattern() noexcept = default;
    explicit HistoryPattern(std::string_view query, HistoryMatchMode mode = HistoryMatchMode::fuzzy) noexcept;

    // No term: every command matches with score 0, in the caller's order.
    [[nodiscard]] [[tbc::hot_path]] inline bool empty() const noexcept {
      return term_count_ == 0;
    }

    // Whether scores order the matches: false when every term is inverse, as fzf leaves the
    // order alone then.
    [[nodiscard]] bool ranks() const noexcept;

    [[nodiscard]] [[tbc::hot_path]] inline std::span<const HistoryTerm> terms() const noexcept {
      return terms_.view().first(term_count_);
    }

    // The characters `term`, one of terms(), compares.
    [[nodiscard]] [[tbc::hot_path]] inline std::span<const std::uint32_t> characters(const HistoryTerm& term) const noexcept {
      return characters_.view().subspan(term.offset, term.length);
    }

  private:
    friend struct HistoryPatternBuilder;

    ds::Array<std::uint32_t, max_characters> characters_{};
    ds::Array<HistoryTerm, max_terms> terms_{};
    std::uint16_t character_count_ = 0;
    std::uint16_t term_count_ = 0;
  };

  // A run of a command's bytes a match covers, [begin, end): what a client highlights.
  struct HistoryMatchRange {
    std::uint32_t begin = 0;
    std::uint32_t end = 0;
  };

  // The ranges a match covers, in order, adjacent ones joined. Past capacity the rest are left
  // out and truncated() says so.
  class HistoryMatchRanges {
  public:
    static constexpr std::size_t capacity = 64;

    [[nodiscard]] std::span<const HistoryMatchRange> view() const noexcept;
    [[nodiscard]] bool truncated() const noexcept;

  private:
    friend struct HistoryMatchWriter;

    ds::Array<HistoryMatchRange, capacity> ranges_{};
    std::uint16_t count_ = 0;
    bool truncated_ = false;
  };

  // How the arena searches. reference is the portable scalar search and the full dynamic
  // programming for a pattern of any length, with the same results as fast; tests and
  // benchmarks compare the two, nothing else has a reason to choose it.
  enum class HistorySearchPath : std::uint8_t {
    fast,
    reference,
  };

  // The scratch a match works in, as fzf's slab: one per thread, reused by every call, never
  // shared between threads at once. About 365 KB, so it belongs on the heap, not the stack. A
  // command past max_characters characters of UTF-8 is matched on its first max_characters
  // (an ASCII command is matched whole); a fuzzy term whose window holds more than max_cells
  // cells is scored greedily, as fzf's FuzzyMatchV1.
  class HistoryMatchArena {
  public:
    static constexpr std::size_t max_characters = std::size_t{8} * 1024;
    static constexpr std::size_t max_cells = std::size_t{64} * 1024;

    HistoryMatchArena() noexcept = default;
    explicit HistoryMatchArena(HistorySearchPath path) noexcept;

    HistoryMatchArena(const HistoryMatchArena&) = delete;
    HistoryMatchArena& operator=(const HistoryMatchArena&) = delete;
    HistoryMatchArena(HistoryMatchArena&&) = delete;
    HistoryMatchArena& operator=(HistoryMatchArena&&) = delete;
    ~HistoryMatchArena() = default;

  private:
    friend struct HistoryMatchScratch;

    // A command's characters, their classes, and one term's keys over them.
    ds::Array<std::uint32_t, max_characters> characters_{};
    ds::Array<std::uint8_t, max_characters> classes_{};
    ds::Array<std::uint32_t, max_characters> keys_{};
    // The window's bonuses, and the score and run of consecutive matches of each of its cells.
    ds::Array<std::uint8_t, max_characters> bonuses_{};
    ds::Array<std::int16_t, max_cells> scores_{};
    ds::Array<std::int16_t, max_cells> runs_{};
    // Per pattern character: where its row starts and ends, and where its cells begin.
    ds::Array<std::uint32_t, HistoryPattern::max_characters> row_first_{};
    ds::Array<std::uint32_t, HistoryPattern::max_characters> row_last_{};
    ds::Array<std::uint32_t, HistoryPattern::max_characters> row_cells_{};
    // The characters a match covers, before they become byte ranges: one per character of the
    // pattern at most, and one per term that covers a whole command.
    ds::Array<HistoryMatchRange, HistoryPattern::max_characters + HistoryPattern::max_terms> marks_{};
    HistorySearchPath path_ = HistorySearchPath::fast;
  };

  // The score of `command` for `pattern`, none when it does not match: the sum of its terms'
  // scores, a fuzzy term's below a quality floor of 8 per character being no match at all.
  // `ranges`, when given, receives the bytes the match covers. Allocates nothing.
  ds::Option<std::uint32_t> historyMatch(const HistoryPattern& pattern, std::string_view command, HistoryMatchArena& arena, HistoryMatchRanges* ranges = nullptr) noexcept;

}

// The module's own ways in, for historyScore: a query taken whole as one case insensitive fuzzy
// term, and a match without the quality floor, as its callers had none.
namespace telar::runtime {

  struct HistoryPatternBuilder {
    // Appends `text`, as typed, as a term like `term` that is case sensitive when `smart_case`
    // finds a capital in it, an alternative of the term before it when `join_previous`.
    static void add(HistoryPattern& pattern, std::span<const std::uint32_t> text, HistoryTerm term, bool smart_case, bool join_previous) noexcept;

    static void literal(HistoryPattern& pattern, std::string_view query) noexcept;
  };

  ds::Option<std::uint32_t> historyMatchWithoutFloor(const HistoryPattern& pattern, std::string_view command, HistoryMatchArena& arena) noexcept;

}
