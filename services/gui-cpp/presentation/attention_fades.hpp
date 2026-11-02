#pragma once

#include "application/pane_layout.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace telar::gui {

struct PaneAttentionKey {
  std::uint64_t pane_id = 0;
  std::uint64_t attachment_generation = 0;

  bool operator==(const PaneAttentionKey &) const = default;
};

struct AttentionFrame {
  float alpha = 1;
  std::optional<std::uint64_t> deadline_ns = std::nullopt;
};

class AttentionFades {
public:
  static constexpr std::uint64_t duration_ns = 360'000'000;
  static constexpr std::size_t capacity = 2 * PaneLayout::maximum_panes;

  void begin() noexcept {
    seen_.fill(false);
  }

  [[nodiscard]] AttentionFrame sample(PaneAttentionKey key, std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    auto index = find(key);
    if (!index) {
      if (count_ == entries_.size()) {
        return {};
      }

      index = count_++;
      entries_[*index] = {.key = key, .started_ns = now_ns};
    }

    seen_[*index] = true;
    const auto started = entries_[*index].started_ns;
    if (now_ns < started) {
      return {.alpha = 0, .deadline_ns = started};
    }

    const auto elapsed = now_ns - started;
    if (elapsed >= duration_ns) {
      return {};
    }

    const auto alpha = static_cast<float>(elapsed) / static_cast<float>(duration_ns);

    return {.alpha = alpha, .deadline_ns = std::min(after(now_ns, interval_ns), after(started, duration_ns))};
  }

  void end() noexcept {
    std::size_t kept = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      if (seen_[index]) {
        entries_[kept++] = entries_[index];
      }
    }

    count_ = kept;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return count_;
  }

private:
  struct Entry {
    PaneAttentionKey key;
    std::uint64_t started_ns = 0;
  };

  [[nodiscard]] static std::uint64_t after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval_ns);
  }

  [[nodiscard]] std::optional<std::size_t> find(PaneAttentionKey key) const noexcept {
    const auto entries = std::span{entries_}.first(count_);
    for (std::size_t index = 0; index < entries.size(); ++index) {
      if (entries[index].key == key) {
        return index;
      }
    }

    return std::nullopt;
  }

  std::array<Entry, capacity> entries_{};
  std::array<bool, capacity> seen_{};
  std::size_t count_ = 0;
};

}
