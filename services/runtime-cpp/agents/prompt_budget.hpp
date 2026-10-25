#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>

namespace telar::runtime {

class PromptBudget {
public:
  bool spend(std::uint64_t sender, std::uint64_t target, std::chrono::steady_clock::time_point now) noexcept {
    auto entry = std::ranges::find_if(pairs_, [&](const Pair &pair) { return pair.sender == sender && pair.target == target; });
    if (entry == pairs_.end()) {
      entry = std::ranges::min_element(pairs_, {}, &Pair::started);
      *entry = Pair{sender, target, now, 0};
    }
    if (now - entry->started >= window) {
      entry->started = now;
      entry->count = 0;
    }
    if (entry->count == prompts_per_window) {
      return false;
    }
    ++entry->count;
    return true;
  }

private:
  struct Pair {
    std::uint64_t sender = 0;
    std::uint64_t target = 0;
    std::chrono::steady_clock::time_point started{};
    unsigned count = 0;
  };

  static constexpr std::chrono::seconds window{60};
  static constexpr unsigned prompts_per_window = 8;
  std::array<Pair, 32> pairs_{};
};

}
