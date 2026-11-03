#pragma once

#include "pick_items.hpp"
#include "telar_base/history/search_policy.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui::components {

class PickMatches {
public:
  struct Match {
    std::uint32_t score = 0;
    std::uint16_t index = 0;
  };

  void collect(const PickItems &items, std::string_view query) {
    count_ = 0;
    for (std::size_t index = 0; index < items.size(); ++index) {
      const auto option = items.at(index);
      auto score = runtime::historyScore(option.label, query);
      if (!score) {
        score = runtime::historyScore(option.detail, query);
      }

      if (score) {
        matches_[count_++] = {.score = *score, .index = static_cast<std::uint16_t>(index)};
      }
    }

    std::ranges::sort(std::span{matches_}.first(count_), [](Match left, Match right) {
      return left.score != right.score ? left.score > right.score : left.index < right.index;
    });
  }

  [[nodiscard]] std::span<const Match> rows() const noexcept {
    return std::span{matches_}.first(count_);
  }

private:
  std::array<Match, PickItems::maximum_items> matches_{};
  std::size_t count_ = 0;
};

}
