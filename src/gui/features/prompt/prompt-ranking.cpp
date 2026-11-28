module telar.gui.features.prompt;

import std;

import telar.base.ds;
import telar.base.history;

namespace telar::gui::features::prompt {

  namespace {

    // The matcher's scratch, about 365 KB, one per thread as the matcher asks: each thread
    // reaches its own, made the first time a menu narrows there and reused by every match after,
    // which then allocates nothing.
    struct [[tbc::shared]] ThreadArena {
      runtime::HistoryMatchArena arena;
    };

    runtime::HistoryMatchArena& arena() noexcept {
      thread_local ThreadArena scratch; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): the thread's own scratch

      return scratch.arena;
    }

    // The pattern of `typed`, its ASCII capitals made small when `folded`.
    runtime::HistoryPattern pattern(std::string_view typed, bool folded) noexcept {
      if (!folded) {
        return runtime::HistoryPattern{typed};
      }

      constexpr unsigned char case_bit = 0x20;
      ds::Array<char, runtime::HistoryPattern::max_characters> lower{};
      const auto size = std::min(typed.size(), lower.size());

      for (std::size_t index = 0; index < size; ++index) {
        const char byte = typed[index];

        lower.atMut(index) = byte >= 'A' && byte <= 'Z' ? static_cast<char>(static_cast<unsigned char>(byte) | case_bit) : byte;
      }

      return runtime::HistoryPattern{std::string_view{lower.data(), size}};
    }

  }

  Ranking::Ranking(std::string_view typed, bool folded) noexcept
      : typed_(typed),
        folded_(folded),
        pattern_(pattern(typed, folded)) {}

  ds::Option<std::int64_t> Ranking::score(std::string_view text) const noexcept {
    // A start as typed beats any score the matcher gives.
    constexpr auto starts = static_cast<std::int64_t>(std::uint64_t{1} << 40U);

    const bool prefix = folded_ ? startsFolded(text, typed_) : text.starts_with(typed_);
    if (prefix) {
      return starts;
    }

    const auto matched = runtime::historyMatch(pattern_, text, arena());

    return matched ? ds::Option{std::int64_t{*matched}} : ds::none;
  }

  bool Ranking::ranges(std::string_view text, HistoryMatchRanges& out) const noexcept {
    return runtime::historyMatch(pattern_, text, arena(), &out).hasValue();
  }

  bool foldable(std::string_view typed) noexcept {
    return std::ranges::any_of(typed, [](char byte) {
      return byte >= 'A' && byte <= 'Z';
    });
  }

  bool menuMatch(std::string_view typed, std::string_view text, HistoryMatchRanges& out) noexcept {
    if (Ranking{typed}.ranges(text, out)) {
      return true;
    }

    return foldable(typed) && Ranking{typed, true}.ranges(text, out);
  }

}
