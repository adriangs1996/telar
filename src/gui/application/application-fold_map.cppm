module;
#include "tbc/annotations.hpp"

export module telar.gui.application:fold_map;

import std;

import telar.base.ds;
import telar.base.memory.allocators;

export namespace telar::gui::application {

  // The rows of a pane's scrollback a folded command hides, and how the rows left shown are
  // counted: a shown row's display index is its row, counted from the top of the scrollback,
  // less the hidden rows above it. Folding changes only what is shown; rows keep their numbers.
  //
  // A span that shows rows stands for its rows in a number of display rows of its own, as a
  // document drawn in place of the text it stands for: its rows map to those display rows in
  // order, the last one taking the rest, and when it shows more rows than it has, its last row
  // stands for the display rows past them.
  template <Allocator Memory = telar::Memory>
  class TBC_GENERIC FoldMap {
  public:
    struct Span {
      // The first row and how many rows from it the span stands for.
      std::uint32_t first = 0;
      std::uint32_t count = 0;
      // The display rows it takes: none for a fold.
      std::uint32_t shown = 0;

      [[nodiscard]] constexpr std::uint64_t end() const noexcept {
        return static_cast<std::uint64_t>(first) + count;
      }

      bool operator==(const Span&) const = default;
    };

    explicit FoldMap(Memory& memory)
        : spans_(memory),
          hidden_before_(memory) {}

    // Takes `spans`, which may come unordered, overlapping or empty: they are sorted, adjacent or
    // overlapping folds joined, and a fold over a span that shows rows hides it all.
    void assign(std::span<const Span> spans) {
      spans_.clear();
      for (const auto& span : spans) {
        if (span.count != 0) {
          spans_.push(span);
        }
      }

      const auto all = spans_.viewMut();

      std::ranges::sort(all, {}, &Span::first);
      std::size_t kept = 0;

      for (const auto span : all) {
        if (kept != 0 && joins(all[kept - 1], span)) {
          continue;
        }

        all[kept++] = span;
      }

      spans_.truncate(kept);
      hidden_before_.clear();
      hidden_before_.resize(spans_.size() + 1, 0);
      for (std::size_t index = 0; index < spans_.size(); ++index) {
        hidden_before_.atMut(index + 1) = hidden_before_[index] + static_cast<std::int64_t>(spans_[index].count) - spans_[index].shown;
      }
    }

    void clear() noexcept {
      spans_.clear();
      hidden_before_.clear();
    }

    [[nodiscard]] bool empty() const noexcept {
      return spans_.empty();
    }

    [[nodiscard]] std::span<const Span> spans() const noexcept {
      return spans_.view();
    }

    // Whether `row` is hidden: under a fold, or past the rows a span shows.
    [[nodiscard]] bool hides(std::uint64_t row) const noexcept {
      const auto found = containing(row);

      return found < spans_.size() && row - spans_[found].first >= spans_[found].shown;
    }

    // How many display rows the first `total` rows take.
    [[nodiscard]] std::uint64_t shownRows(std::uint64_t total) const noexcept {
      const auto index = lastStartingBefore(total);
      if (index == spans_.size()) {
        return total;
      }

      const auto& span = spans_[index];
      if (total < span.end()) {
        return start(index) + std::min<std::uint64_t>(total - span.first, span.shown);
      }

      return static_cast<std::uint64_t>(static_cast<std::int64_t>(total) - hidden_before_[index + 1]);
    }

    // The display index of `row`. A hidden row has the index of the first shown row under its
    // fold; a row of a span that shows rows, the index of its own, or of the span's last.
    [[nodiscard]] std::uint64_t display(std::uint64_t row) const noexcept {
      const auto index = lastStartingBefore(row + 1);
      if (index == spans_.size()) {
        return row;
      }

      const auto& span = spans_[index];
      if (row < span.end()) {
        return start(index) + (span.shown == 0 ? 0 : std::min<std::uint64_t>(row - span.first, span.shown - 1));
      }

      return static_cast<std::uint64_t>(static_cast<std::int64_t>(row) - hidden_before_[index + 1]);
    }

    // The row shown at display index `index`.
    [[nodiscard]] std::uint64_t row(std::uint64_t index) const noexcept {
      // The last span whose first display row is at or above `index`.
      std::size_t low = 0;
      std::size_t high = spans_.size();

      while (low < high) {
        const auto middle = low + ((high - low) / 2);
        if (start(middle) <= index) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }

      if (low == 0) {
        return index;
      }

      const auto& span = spans_[low - 1];
      const auto offset = index - start(low - 1);
      if (offset < span.shown) {
        return span.first + std::min<std::uint64_t>(offset, span.count - 1);
      }

      return static_cast<std::uint64_t>(static_cast<std::int64_t>(index) + hidden_before_[low]);
    }

    // The span that shows rows at display index `index`, if one does.
    [[nodiscard]] const Span* showing(std::uint64_t index) const noexcept {
      for (std::size_t span = 0; span < spans_.size() && start(span) <= index; ++span) {
        if (spans_[span].shown != 0 && index - start(span) < spans_[span].shown) {
          return &spans_[span];
        }
      }

      return nullptr;
    }

  private:
    // The fold that hides `row`, or the number of folds.
    [[nodiscard]] std::size_t containing(std::uint64_t row) const noexcept {
      const auto after = std::ranges::upper_bound(spans_, row, {}, [](const Span& span) {
        return static_cast<std::uint64_t>(span.first);
      });
      if (after == spans_.begin()) {
        return spans_.size();
      }

      const auto index = static_cast<std::size_t>(after - spans_.begin()) - 1;

      return row < spans_[index].end() ? index : spans_.size();
    }

    // Whether `span`, which starts at or after `previous`, joins it: it overlaps it, or both are
    // folds and it starts where `previous` ends. When either is a fold, `previous` becomes one fold
    // over the rows of both.
    static bool joins(Span& previous, const Span& span) noexcept {
      const bool folds = previous.shown == 0 && span.shown == 0;
      const bool overlaps = span.first < previous.end() || (folds && span.first == previous.end());
      if (!overlaps) {
        return false;
      }

      if (previous.shown == 0 || span.shown == 0) {
        const auto end = std::max(previous.end(), span.end());

        previous.count = static_cast<std::uint32_t>(std::min<std::uint64_t>(end - previous.first, std::numeric_limits<std::uint32_t>::max()));
        previous.shown = 0;
      }

      return true;
    }

    ds::Vec<Span, Memory> spans_;

    // The first display row of span `index`.
    [[nodiscard]] std::uint64_t start(std::size_t index) const noexcept {
      return static_cast<std::uint64_t>(static_cast<std::int64_t>(spans_[index].first) - hidden_before_[index]);
    }

    // The last span that starts before `row`, or the number of spans.
    [[nodiscard]] std::size_t lastStartingBefore(std::uint64_t row) const noexcept {
      const auto after = std::ranges::lower_bound(spans_, row, {}, [](const Span& span) {
        return static_cast<std::uint64_t>(span.first);
      });

      return after == spans_.begin() ? spans_.size() : static_cast<std::size_t>(after - spans_.begin()) - 1;
    }

    // Display rows less than rows before each span: a fold adds its rows, a span that shows rows
    // its rows less what it shows.
    ds::Vec<std::int64_t, Memory> hidden_before_;
  };

}
