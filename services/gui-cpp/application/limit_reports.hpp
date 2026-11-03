#pragma once

#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui {

class LimitReports {
public:
  static constexpr std::size_t capacity = 128;
  static constexpr std::size_t name_capacity = 64;
  static constexpr std::size_t noun_capacity = 32;
  static constexpr std::size_t route_capacity = 32;
  static constexpr std::size_t description_capacity = name_capacity + noun_capacity + 96;
  static constexpr std::uint64_t notice_interval_ms = 60'000;
  static constexpr std::uint64_t report_interval_ms = 1000;

  struct Time {
    std::int64_t awake_ms = 0;
    std::int64_t real_ms = 0;
  };

  struct Row {
    runtime::FixedText<name_capacity> name;
    runtime::FixedText<noun_capacity> noun;
    runtime::FixedText<route_capacity> route;
    std::uint64_t value = 0;
    std::optional<std::uint64_t> requested = std::nullopt;
    std::uint64_t hits = 0;
    std::uint32_t unreported = 0;
    std::int64_t last_ms = 0;
    std::optional<std::int64_t> shown_ms = std::nullopt;
    std::optional<std::int64_t> reported_ms = std::nullopt;

    [[nodiscard]] LimitReach reach() const noexcept {
      return {.name = name.view(), .noun = noun.view(), .value = value, .requested = requested, .route = route.view()};
    }
  };

  struct Slot {
    std::size_t value = 0;
  };

  struct Recorded {
    Slot slot{};
    bool show = false;
  };

  [[nodiscard]] Recorded record(LimitReach reach, Time sampled, std::uint32_t hits) {
    const auto name = reach.name.substr(0, name_capacity);
    const auto found = find(name);
    const auto slot = found ? *found : insert(name);
    auto &row = rows_[slot];
    row.noun.assign(reach.noun.substr(0, noun_capacity));
    row.route.assign(reach.route.substr(0, route_capacity));
    row.value = reach.value;
    if (reach.requested) {
      row.requested = reach.requested;
    }

    row.hits = saturatedAdd(row.hits, static_cast<std::uint64_t>(hits));
    row.unreported = saturatedAdd(row.unreported, hits);
    row.last_ms = sampled.real_ms;
    const bool show = !row.shown_ms || elapsed(sampled.awake_ms, *row.shown_ms, notice_interval_ms);
    if (show) {
      row.shown_ms = sampled.awake_ms;
    }

    return {.slot = {slot}, .show = show};
  }

  [[nodiscard]] std::optional<std::uint32_t> takeReport(Slot slot, std::int64_t awake_ms) noexcept {
    auto &row = rows_[slot.value];
    if (row.unreported == 0 || (row.reported_ms && !elapsed(awake_ms, *row.reported_ms, report_interval_ms))) {
      return std::nullopt;
    }

    const auto hits = std::exchange(row.unreported, 0);
    row.reported_ms = awake_ms;

    return hits;
  }

  void restoreReport(Slot slot, std::uint32_t hits) noexcept {
    auto &row = rows_[slot.value];
    row.unreported = saturatedAdd(row.unreported, hits);
    row.reported_ms.reset();
  }

  [[nodiscard]] const Row &row(Slot slot) const {
    return rows_.at(slot.value);
  }

  [[nodiscard]] std::span<const Row> rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  [[nodiscard]] std::uint64_t evicted() const noexcept {
    return evicted_;
  }

  [[nodiscard]] static BoundedText<description_capacity> describe(LimitReach reach, std::uint64_t hits) {
    BoundedText<description_capacity> text;
    text.append(reach.name);
    text.append(": ");
    if (reach.requested) {
      text.appendDecimal(*reach.requested);
      appendNoun(text, reach.noun);
      text.append("; limit ");
      text.appendDecimal(reach.value);
    } else if (reach.value == 0) {
      text.append("limit reached");
    } else {
      text.append("limit ");
      text.appendDecimal(reach.value);
      appendNoun(text, reach.noun);
      text.append(" reached");
    }

    if (hits > 1) {
      text.append(" (");
      text.appendDecimal(hits);
      text.append(" times)");
    }

    return text;
  }

private:
  template <typename Number>
  [[nodiscard]] static Number saturatedAdd(Number left, Number right) noexcept {
    return left + std::min(right, std::numeric_limits<Number>::max() - left);
  }

  [[nodiscard]] static bool elapsed(std::int64_t now_ms, std::int64_t since_ms, std::uint64_t interval_ms) noexcept {
    return now_ms >= since_ms && static_cast<std::uint64_t>(now_ms) - static_cast<std::uint64_t>(since_ms) >= interval_ms;
  }

  static void appendNoun(BoundedText<description_capacity> &text, std::string_view noun) {
    if (!noun.empty()) {
      text.append(" ");
      text.append(noun);
    }
  }

  [[nodiscard]] std::optional<std::size_t> find(std::string_view name) const noexcept {
    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].name.view() == name) {
        return slot;
      }
    }

    return std::nullopt;
  }

  std::size_t insert(std::string_view name) {
    std::size_t slot = count_;
    if (count_ < capacity) {
      ++count_;
    } else {
      slot = oldest();
      evicted_ = saturatedAdd(evicted_, std::uint64_t{1});
    }

    rows_[slot] = {};
    rows_[slot].name.assign(name);

    return slot;
  }

  [[nodiscard]] std::size_t oldest() const noexcept {
    std::size_t found = 0;
    for (std::size_t slot = 1; slot < count_; ++slot) {
      if (rows_[slot].last_ms < rows_[found].last_ms) {
        found = slot;
      }
    }

    return found;
  }

  std::array<Row, capacity> rows_{};
  std::size_t count_ = 0;
  std::uint64_t evicted_ = 0;
};

}
