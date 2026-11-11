#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

namespace telar::gui {

// The rows of a pane's scrollback a folded command hides, and how the rows left shown are
// counted: a shown row's display index is its row, counted from the top of the scrollback,
// less the hidden rows above it. Folding changes only what is shown; rows keep their numbers.
template <typename Allocator = std::allocator<std::uint32_t>>
class FoldMap {
public:
  struct Span {
    // The first hidden row and how many rows are hidden from it.
    std::uint32_t first = 0;
    std::uint32_t count = 0;

    [[nodiscard]] constexpr std::uint64_t end() const noexcept {
      return static_cast<std::uint64_t>(first) + count;
    }

    bool operator==(const Span &) const = default;
  };

  using SpanAllocator = std::allocator_traits<Allocator>::template rebind_alloc<Span>;
  using CountAllocator = std::allocator_traits<Allocator>::template rebind_alloc<std::uint64_t>;

  FoldMap() = default;
  explicit FoldMap(const Allocator &allocator)
      : spans_(SpanAllocator{allocator}),
        hidden_before_(CountAllocator{allocator}) {}

  // Hides `spans`, which may come unordered, overlapping or empty: they are sorted and joined.
  void assign(std::span<const Span> spans) {
    spans_.assign(spans.begin(), spans.end());
    std::erase_if(spans_, [](const Span &span) { return span.count == 0; });
    std::ranges::sort(spans_, {}, &Span::first);
    std::size_t kept = 0;
    for (const auto &span : spans_) {
      if (kept != 0 && span.first <= spans_[kept - 1].end()) {
        auto &previous = spans_[kept - 1];
        const auto end = std::max(previous.end(), span.end());
        previous.count = static_cast<std::uint32_t>(std::min<std::uint64_t>(end - previous.first, UINT32_MAX));
        continue;
      }
      spans_[kept++] = span;
    }
    spans_.resize(kept);
    hidden_before_.assign(spans_.size() + 1, 0);
    for (std::size_t index = 0; index < spans_.size(); ++index) {
      hidden_before_[index + 1] = hidden_before_[index] + spans_[index].count;
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
    return spans_;
  }

  // Whether `row` is hidden.
  [[nodiscard]] bool hides(std::uint64_t row) const noexcept {
    const auto found = containing(row);
    return found < spans_.size();
  }

  // Rows hidden above `row`, within the first `total` rows.
  [[nodiscard]] std::uint64_t hiddenBefore(std::uint64_t row) const noexcept {
    if (spans_.empty()) {
      return 0;
    }
    const auto after = std::ranges::upper_bound(spans_, row, {}, [](const Span &span) { return static_cast<std::uint64_t>(span.first); });
    const auto index = static_cast<std::size_t>(after - spans_.begin());
    if (index == 0) {
      return 0;
    }
    const auto &span = spans_[index - 1];
    return hidden_before_[index - 1] + std::min<std::uint64_t>(span.count, row - span.first);
  }

  // How many of the first `total` rows are shown.
  [[nodiscard]] std::uint64_t shownRows(std::uint64_t total) const noexcept {
    return total - hiddenBefore(total);
  }

  // The display index of `row`. A hidden row has the index of the first shown row under its fold.
  [[nodiscard]] std::uint64_t display(std::uint64_t row) const noexcept {
    return row - hiddenBefore(row);
  }

  // The row shown at display index `index`.
  [[nodiscard]] std::uint64_t row(std::uint64_t index) const noexcept {
    // The last fold whose first row would be shown at or above `index`, were it unfolded.
    std::size_t low = 0;
    std::size_t high = spans_.size();
    while (low < high) {
      const auto middle = low + ((high - low) / 2);
      if (spans_[middle].first - hidden_before_[middle] <= index) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }

    return index + (low == 0 ? 0 : hidden_before_[low]);
  }

private:
  // The fold that hides `row`, or the number of folds.
  [[nodiscard]] std::size_t containing(std::uint64_t row) const noexcept {
    const auto after = std::ranges::upper_bound(spans_, row, {}, [](const Span &span) { return static_cast<std::uint64_t>(span.first); });
    if (after == spans_.begin()) {
      return spans_.size();
    }
    const auto index = static_cast<std::size_t>(after - spans_.begin()) - 1;
    return row < spans_[index].end() ? index : spans_.size();
  }

  std::vector<Span, SpanAllocator> spans_;
  std::vector<std::uint64_t, CountAllocator> hidden_before_;
};

}
