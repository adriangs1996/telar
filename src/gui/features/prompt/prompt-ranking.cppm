// How the completion menu ranks its choices against the word typed: the history's matcher, fzf's
// FuzzyMatchV2 with its smart case, a choice that starts with the word as typed first.
export module telar.gui.features.prompt:ranking;

import std;

import telar.base.ds;
import telar.base.history;

export namespace telar::gui::features::prompt {

  // The bytes of a choice the word typed matches, for the menu to mark.
  using runtime::HistoryMatchRanges;

  // The ranking for one word typed, parsed once for every choice it is matched against; with
  // `folded`, the word's ASCII capitals made small, as the menu ranks once nothing matches the
  // word as typed (`A` then finds `project-a`).
  class Ranking {
  public:
    explicit Ranking(std::string_view typed, bool folded = false) noexcept;

    // How well the word matches `text`: none when it does not. Higher is better, and a text that
    // starts with the word as typed ranks above every one that does not.
    [[nodiscard]] ds::Option<std::int64_t> score(std::string_view text) const noexcept;

    // The bytes of `text` the word matches, into `out`; false when it does not match.
    bool ranges(std::string_view text, HistoryMatchRanges& out) const noexcept;

  private:
    std::string_view typed_;
    bool folded_ = false;
    runtime::HistoryPattern pattern_;
  };

  // Whether a folded ranking can find more than the word as typed: it holds an ASCII capital.
  [[nodiscard]] bool foldable(std::string_view typed) noexcept;

  // The bytes of `text` that `typed` marks in the menu: as typed, or folded when it does not
  // match so, as the menu narrowed it. False when neither matches.
  bool menuMatch(std::string_view typed, std::string_view text, HistoryMatchRanges& out) noexcept;

}
