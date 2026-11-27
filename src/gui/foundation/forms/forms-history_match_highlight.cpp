module telar.gui.foundation.forms;

import std;

import telar.base.history;

namespace telar::gui::inline foundation::inline forms {

  namespace {

    // The matcher's scratch, each thread's own so nothing else reaches it while it is in use.
    struct [[tbc::shared]] ThreadArena {
      std::unique_ptr<runtime::HistoryMatchArena> arena;
    };

    // The thread's arena, made on the heap for its size the first time a highlight is read.
    runtime::HistoryMatchArena& arena() {
// A thread that exits frees its arena.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
      thread_local ThreadArena local;
#pragma clang diagnostic pop

      if (local.arena == nullptr) {
        local.arena = std::make_unique<runtime::HistoryMatchArena>();
      }

      return *local.arena;
    }

  }

  // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): the command is matched by the query, as the declaration names them
  HistoryMatchRanges HistoryMatchRanges::find(std::string_view command, std::string_view query) {
    HistoryMatchRanges result;
    runtime::HistoryMatchRanges matched;

    if (query.empty()) {
      return result;
    }

    // The runtime's own matcher, so what is lit is what it matched: fzf's, with its extended
    // syntax and smart case.
    const runtime::HistoryPattern pattern{query};
    if (!runtime::historyMatch(pattern, command, arena(), &matched)) {
      return result;
    }

    for (const auto range : matched.view()) {
      result.append({.offset = range.begin, .length = range.end - range.begin});
    }

    return result;
  }

  void HistoryMatchRanges::append(HistoryMatchRange range) noexcept {
    if (range.length == 0) {
      return;
    }

    if (count_ != 0) {
      auto& last = ranges_.atMut(count_ - 1);
      const auto end = static_cast<std::uint64_t>(last.offset) + last.length;
      if (range.offset < end) {
        return;
      }

      if (range.offset == end) {
        last.length += range.length;
        return;
      }
    }

    if (count_ < capacity) {
      ranges_.atMut(count_++) = range;
    }
  }

  std::span<const HistoryMatchRange> HistoryMatchRanges::view() const noexcept {
    return std::span{ranges_}.first(count_);
  }

  bool HistoryMatchRanges::covers(std::size_t offset, std::size_t length) const noexcept {
    const auto end = offset + length;

    return std::ranges::any_of(view(), [&](const HistoryMatchRange& range) {
      return range.offset < end && offset < static_cast<std::size_t>(range.offset) + range.length;
    });
  }

  bool HistoryMatchRanges::operator==(const HistoryMatchRanges& other) const noexcept {
    return std::ranges::equal(view(), other.view());
  }

  HistoryMatchHighlight::HistoryMatchHighlight(const HistoryMatchRanges& ranges) noexcept
      : ranges_(&ranges) {}

  std::size_t HistoryMatchHighlight::matched() const noexcept {
    return matched_;
  }

}
