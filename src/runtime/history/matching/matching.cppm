export module telar.runtime.history.matching;

import std;
import telar.base.memory.allocators;
import telar.base.history;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.text.pattern;

// The one place the history matches a query against a command and weighs what it found. The
// matcher, its syntax and the ranking formula are telar.base.history's; every search of the
// store and of its index calls them through here, so replacing either changes this module alone.
// The regex mode is telar.base.text.pattern's engine, matching as the history folds case.
export namespace telar::runtime {

  // A command's text as the history matches it, as it ran. `folded` is the same text for a
  // caller that holds it folded; the matcher folds what it needs itself.
  struct HistoryText {
    std::string_view original;
    std::string_view folded;
  };

  // What one thread matches in, reused by every match it makes: the matcher's arena, about
  // 365 KB, and the regex's buffers.
  class HistoryMatchWork {
  public:
    explicit HistoryMatchWork(ConcurrentMemory& memory);

  private:
    friend class HistoryMatcher;

    ds::Box<HistoryMatchArena, ConcurrentMemory> arena_;
    ds::Box<PatternScratch, ConcurrentMemory> pattern_;
    HistoryMatchRanges ranges_;
  };

  class HistoryMatcher {
  public:
    // Throws RequestError(invalid_request) for a regex that does not compile.
    HistoryMatcher(ConcurrentMemory& memory, HistoryMatch mode, std::string_view query);

    // Threads share one matcher by reference while a search runs.
    HistoryMatcher(const HistoryMatcher&) = delete;
    HistoryMatcher& operator=(const HistoryMatcher&) = delete;
    HistoryMatcher(HistoryMatcher&&) = delete;
    HistoryMatcher& operator=(HistoryMatcher&&) = delete;
    ~HistoryMatcher() = default;

    [[nodiscard]] HistoryMatch mode() const noexcept;
    [[nodiscard]] std::string_view query() const noexcept;
    [[nodiscard]] bool empty() const noexcept;

    // Whether every command this query matches is one `previous_query` matched too: the same
    // query typed further, which a search need only test against what the last one found. A
    // query with an alternative, an exclusion, an anchor at its end or an escape never narrows.
    // A command the matcher's quality floor turned down for the shorter query is not tried
    // again, as fzf's cache does not try one again either.
    [[nodiscard]] bool narrows(HistoryMatch previous_mode, std::string_view previous_query) const noexcept;

    // How well the query matches `text`, higher better; none when it does not. Reads nothing but
    // its arguments, so threads may share one matcher, each with its own scratch.
    [[nodiscard]] ds::Option<std::uint32_t> score(HistoryText text, HistoryMatchWork& scratch) const noexcept;

    // Where the query matches `text`, as byte ranges of it in order; the ranges written, at most
    // out.size().
    std::size_t ranges(HistoryText text, std::span<HistoryRange> out, HistoryMatchWork& scratch) const noexcept;

  private:
    HistoryMatch mode_;
    ds::String<ConcurrentMemory> query_;
    HistoryPattern pattern_;
    Pattern regex_;
  };

  // What the history knows of a command besides how well it matched, which weighs it.
  struct HistoryPriors {
    std::uint32_t runs = 0;
    std::int64_t last_ms = 0;
    std::int64_t now_ms = 0;
    bool same_cwd = false;
    bool same_workspace = false;
    bool same_pane = false;
    // Its newest run failed.
    bool recent_failure = false;
    // How often it followed the asking pane's previous command, and how often a person chose it
    // from the history and ran it unchanged.
    std::uint32_t follows = 0;
    std::uint32_t selected = 0;
  };

  // The key a ranked listing sorts by, higher first: historyRank's.
  [[nodiscard]] std::uint64_t rankHistory(std::uint32_t score, const HistoryPriors& priors) noexcept;

  // What a command is for the sequence it runs in, historyTemplate's shape of it, as a hash:
  // `git commit -m "fix"` and `git commit -m "docs"` are one.
  [[nodiscard]] std::uint64_t historyTemplateKey(std::string_view command) noexcept;

}
