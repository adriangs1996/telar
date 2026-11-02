#pragma once

#include "history/search_policy.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui {

template <std::semiregular Target, std::size_t Capacity>
class RankedMatches {
  static_assert(Capacity > 0);

public:
  struct Match {
    Target target{};
    std::uint32_t score = 0;
  };

  void clear() noexcept {
    length_ = 0;
  }

  void add(Target target, std::string_view label, std::string_view query) {
    const auto score = runtime::historyScore(label, query);
    if (!score) {
      return;
    }

    addScored(std::move(target), *score);
  }

  void addScored(Target target, std::uint32_t score) {
    auto position = length_;
    while (position != 0 && matches_[position - 1].score < score) {
      --position;
    }

    if (position == Capacity) {
      return;
    }

    auto tail = std::min(length_, Capacity - 1);
    while (tail > position) {
      matches_[tail] = std::move(matches_[tail - 1]);
      --tail;
    }

    matches_[position] = {.target = std::move(target), .score = score};
    length_ = std::min(length_ + 1, Capacity);
  }

  [[nodiscard]] std::span<const Match> rows() const noexcept {
    return std::span{matches_}.first(length_);
  }

private:
  std::array<Match, Capacity> matches_{};
  std::size_t length_ = 0;
};

}
