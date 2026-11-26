export module telar.gui.foundation.text:ranked_matches;

import std;

import telar.base.history;
import telar.base.ds;

// Interface: palette/ranked_matches.cppm
export {
  namespace telar::gui::inline foundation::inline text {

    // Generic over the caller's target and capacity, so it stays whole for each importer.
    template <std::semiregular Target, std::size_t Capacity>
    class [[tbc::generic]] RankedMatches {
      static_assert(Capacity > 0);

    public:
      struct Match {
        Target target{};
        std::uint32_t score = 0;
      };

      inline void clear() noexcept {
        length_ = 0;
      }

      inline void add(Target target, std::string_view label, std::string_view query) {
        const auto score = runtime::historyScore(label, query);
        if (!score) {
          return;
        }

        addScored(std::move(target), *score);
      }

      inline void addScored(Target target, std::uint32_t score) {
        auto position = length_;

        while (position != 0 && matches_[position - 1].score < score) {
          --position;
        }

        if (position == Capacity) {
          return;
        }

        auto tail = std::min(length_, Capacity - 1);

        while (tail > position) {
          matches_.atMut(tail) = std::move(matches_.atMut(tail - 1));
          --tail;
        }

        matches_.atMut(position) = {.target = std::move(target), .score = score};
        length_ = std::min(length_ + 1, Capacity);
      }

      [[nodiscard]] inline std::span<const Match> rows() const noexcept {
        return std::span{matches_}.first(length_);
      }

    private:
      ds::Array<Match, Capacity> matches_{};
      std::size_t length_ = 0;
    };

  }
}
