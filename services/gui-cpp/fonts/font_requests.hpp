#pragma once

#include "core/placeholder_prefix.hpp"
#include "font_query.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui::fonts {

class FontRequests {
public:
  static constexpr std::size_t pending_capacity = 16;
  static constexpr unsigned maximum_retries = 4;

  void request(std::string_view text) {
    if (text.starts_with(placeholder_prefix) || misses_.contains(text) || queued(text)) {
      return;
    }

    const auto query = FontQuery::create(text);
    if (!query) {
      misses_.remember(text);
      return;
    }

    if (count_ == pending_.size()) {
      turned_away_ = true;
      return;
    }

    pending_[(head_ + count_) % pending_.size()] = *query;
    ++count_;
  }

  [[nodiscard]] std::optional<FontQuery> take() {
    if (in_flight_ || count_ == 0) {
      return std::nullopt;
    }

    in_flight_ = pending_[head_];
    head_ = (head_ + 1) % pending_.size();
    --count_;

    return in_flight_;
  }

  [[nodiscard]] bool finish(const FontQuery &query, bool changed) {
    if (in_flight_ && in_flight_->text() == query.text()) {
      in_flight_.reset();
    }

    if (changed) {
      retries_ = 0;
    } else {
      misses_.remember(query.text());
    }

    if (turned_away_ && count_ == 0 && !in_flight_) {
      turned_away_ = false;
      if (retries_ < maximum_retries) {
        ++retries_;
        return true;
      }
    }

    return changed;
  }

private:
  class Misses {
  public:
    [[nodiscard]] bool contains(std::string_view text) const {
      const auto hash = digest(text);
      const auto entries = bucket(hash);

      return std::ranges::find(entries, hash) != entries.end();
    }

    void remember(std::string_view text) {
      const auto hash = digest(text);
      auto entries = bucket(hash);
      for (auto &entry : entries) {
        if (entry == hash) {
          return;
        }

        if (entry == 0) {
          entry = hash;
          return;
        }
      }

      auto &next = next_[hash % sets];
      entries[next] = hash;
      next = (next + 1) % ways;
    }

  private:
    static constexpr std::size_t capacity = 4096;
    static constexpr std::size_t ways = 8;
    static constexpr std::size_t sets = capacity / ways;

    static std::uint64_t digest(std::string_view text) {
      return static_cast<std::uint64_t>(std::hash<std::string_view>{}(text)) | std::uint64_t{1};
    }

    [[nodiscard]] std::span<std::uint64_t> bucket(std::uint64_t hash) noexcept {
      return std::span{hashes_}.subspan((hash % sets) * ways, ways);
    }

    [[nodiscard]] std::span<const std::uint64_t> bucket(std::uint64_t hash) const noexcept {
      return std::span{hashes_}.subspan((hash % sets) * ways, ways);
    }

    std::array<std::uint64_t, capacity> hashes_{};
    std::array<std::size_t, sets> next_{};
  };

  [[nodiscard]] bool queued(std::string_view text) const {
    if (in_flight_ && in_flight_->text() == text) {
      return true;
    }

    for (std::size_t offset = 0; offset < count_; ++offset) {
      if (pending_[(head_ + offset) % pending_.size()].text() == text) {
        return true;
      }
    }

    return false;
  }

  std::array<FontQuery, pending_capacity> pending_{};
  std::optional<FontQuery> in_flight_;
  Misses misses_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
  unsigned retries_ = 0;
  bool turned_away_ = false;
};

}
