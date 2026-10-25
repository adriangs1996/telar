#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstdio>

namespace telar::runtime::config {

class LimitNotices {
public:
  void add(const LimitReach &reach) noexcept {
    for (auto &entry : std::span{entries_}.first(count_)) {
      if (entry.name == reach.name) {
        if (reach.requested) {
          entry.requested = std::max(entry.requested.value_or(0), *reach.requested);
        }
        return;
      }
    }
    if (count_ == entries_.size()) {
      return;
    }

    entries_[count_++] = reach;
  }

  std::span<const LimitReach> entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

  void print() const noexcept {
    for (const auto &entry : entries()) {
      std::fprintf(stderr, "telar config: limit reached, the excess was left out: %.*s: ", static_cast<int>(entry.name.size()), entry.name.data());
      const auto *separator = entry.noun.empty() ? "" : " ";
      if (entry.requested) {
        std::fprintf(stderr, "%llu%s%.*s; limit %llu\n", *entry.requested, separator, static_cast<int>(entry.noun.size()), entry.noun.data(), entry.value);
      } else if (entry.value == 0) {
        std::fputs("limit reached\n", stderr);
      } else {
        std::fprintf(stderr, "limit %llu%s%.*s reached\n", entry.value, separator, static_cast<int>(entry.noun.size()), entry.noun.data());
      }
    }
  }

private:
  std::array<LimitReach, 16> entries_{};
  std::size_t count_ = 0;
};

}
