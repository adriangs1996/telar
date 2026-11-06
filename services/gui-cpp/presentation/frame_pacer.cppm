module;

#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>


#include "telar_client/serializers/telar_cells.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>


#include <cmath>


#include "telar_client/serializers/telar_messages.hpp"

export module telar.gui.presentation.frame_pacer;

export import telar.gui.application.sound_playback;


export import telar.gui.core.metrics;

// Interface: presentation/attention_fades.cppm
export {
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

  inline void begin() noexcept {
    seen_.fill(false);
  }

  [[nodiscard]] inline AttentionFrame sample(PaneAttentionKey key, std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
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

  inline void end() noexcept {
    std::size_t kept = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      if (seen_[index]) {
        entries_[kept++] = entries_[index];
      }
    }

    count_ = kept;
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return count_;
  }

private:
  struct Entry {
    PaneAttentionKey key;
    std::uint64_t started_ns = 0;
  };

  [[nodiscard]] inline static std::uint64_t after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval_ns);
  }

  [[nodiscard]] inline std::optional<std::size_t> find(PaneAttentionKey key) const noexcept {
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
}

// Interface: presentation/frame_pacer.cppm
export {
namespace telar::gui {

class FramePacer {
public:
  struct Pane {
    std::uint64_t pane_id = 0;
    std::uint64_t frame_id = 0;
    bool attached = false;
    std::uint64_t attachment_generation = 0;
    std::uint64_t graphics_revision = 0;
  };

  static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
  static constexpr std::uint64_t default_interval_ns = nanoseconds_per_second / Configuration::default_fps;
  static constexpr std::uint64_t minimum_interval_ns = nanoseconds_per_second / Configuration::maximum_fps;
  static constexpr std::uint64_t maximum_interval_ns = nanoseconds_per_second / Configuration::minimum_fps;
  static constexpr std::uint64_t input_grace_ns = 30'000'000;
  static constexpr std::uint32_t input_frame_budget = 16;
  static constexpr std::size_t capacity = PaneLayout::maximum_panes;

  [[nodiscard]] inline static std::uint64_t resolveInterval(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept {
    const auto cap_interval_ns = maximum_fps ? nanoseconds_per_second / std::max<std::uint16_t>(*maximum_fps, 1) : 0;

    return std::clamp(std::max(display_interval_ns, cap_interval_ns), minimum_interval_ns, maximum_interval_ns);
  }

  inline std::uint64_t configure(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept {
    interval_ns_ = resolveInterval(display_interval_ns, maximum_fps);

    return interval_ns_;
  }

  [[nodiscard]] inline std::uint64_t interval() const noexcept {
    return interval_ns_;
  }

  inline void noteInput(Pane pane, std::uint64_t now_ns) noexcept {
    if (!pane.attached || pane.pane_id == 0) {
      return;
    }

    std::optional<std::size_t> vacant;
    std::size_t oldest = 0;
    auto oldest_started_ns = std::numeric_limits<std::uint64_t>::max();
    for (std::size_t index = 0; index < inputs_.size(); ++index) {
      const auto &previous = inputs_[index];
      if (!previous) {
        if (!vacant) {
          vacant = index;
        }

        continue;
      }

      if (previous->pane.pane_id == pane.pane_id) {
        if (!previous->rejects(pane, now_ns)) {
          inputs_[index] = InputGrace{.pane = pane, .started_ns = now_ns};
        }

        return;
      }

      if (previous->started_ns < oldest_started_ns) {
        oldest = index;
        oldest_started_ns = previous->started_ns;
      }
    }

    inputs_[vacant.value_or(oldest)] = InputGrace{.pane = pane, .started_ns = now_ns};
  }

  [[nodiscard]] inline bool canAdvanceInput(Pane pane, std::uint64_t now_ns) const noexcept {
    constexpr std::uint64_t idle_intervals = 2;
    if (last_preparation_ns_ && (now_ns < *last_preparation_ns_ || now_ns - *last_preparation_ns_ < interval_ns_ * idle_intervals)) {
      return false;
    }

    return std::ranges::any_of(inputs_, [&](const auto &grace) {
      return grace && grace->active(now_ns) && grace->includes(pane);
    });
  }

  [[nodiscard]] inline std::optional<std::uint64_t> waitUntil(std::span<const Pane> panes, std::uint64_t now_ns) const noexcept {
    if (ordinaryAvailable(now_ns)) {
      return std::nullopt;
    }

    for (const auto &grace : inputs_) {
      if (grace && grace->active(now_ns) && std::ranges::any_of(panes, [&](Pane pane) {
            return grace->includes(pane);
          })) {
        return std::nullopt;
      }
    }

    return after(anchor_ns_.value_or(now_ns), interval_ns_);
  }

  inline void record(std::span<const Pane> panes, std::uint64_t now_ns) noexcept {
    const auto due_ns = anchor_ns_ ? std::optional{after(*anchor_ns_, interval_ns_)} : std::nullopt;
    const bool scheduled = due_ns && *due_ns <= now_ns && now_ns - *due_ns < interval_ns_;
    const bool ordinary_available = ordinaryAvailable(now_ns);

    for (auto &grace : inputs_) {
      if (!grace || now_ns < grace->started_ns || (!ordinary_available && !grace->active(now_ns))) {
        continue;
      }

      const auto matched = std::ranges::find_if(panes, [&](Pane pane) {
        return grace->includes(pane);
      });
      if (matched == panes.end()) {
        continue;
      }

      if (!ordinary_available && !scheduled && grace->frames_left != 0) {
        --grace->frames_left;
      }

      grace->pane = *matched;
    }

    anchor_ns_ = scheduled ? *due_ns : now_ns;
    last_preparation_ns_ = now_ns;
  }

private:
  struct InputGrace {
    Pane pane;
    std::uint64_t started_ns;
    std::uint32_t frames_left = input_frame_budget;

    [[nodiscard]] inline bool includes(Pane candidate) const noexcept {
      return candidate.attached && candidate.pane_id == pane.pane_id && candidate.attachment_generation == pane.attachment_generation && candidate.frame_id >= pane.frame_id && candidate.graphics_revision >= pane.graphics_revision && (candidate.frame_id > pane.frame_id || candidate.graphics_revision > pane.graphics_revision);
    }

    [[nodiscard]] inline bool rejects(Pane candidate, std::uint64_t now_ns) const noexcept {
      return pane.attachment_generation > candidate.attachment_generation || now_ns < started_ns || (pane.attachment_generation == candidate.attachment_generation && (pane.frame_id > candidate.frame_id || pane.graphics_revision > candidate.graphics_revision));
    }

    [[nodiscard]] inline bool active(std::uint64_t now_ns) const noexcept {
      return now_ns >= started_ns && now_ns - started_ns < input_grace_ns && frames_left != 0;
    }
  };

  [[nodiscard]] inline static std::uint64_t after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval_ns);
  }

  [[nodiscard]] inline bool ordinaryAvailable(std::uint64_t now_ns) const noexcept {
    return !anchor_ns_ || (now_ns >= *anchor_ns_ && now_ns - *anchor_ns_ >= interval_ns_);
  }

  std::array<std::optional<InputGrace>, capacity> inputs_{};
  std::uint64_t interval_ns_ = default_interval_ns;
  std::optional<std::uint64_t> anchor_ns_;
  std::optional<std::uint64_t> last_preparation_ns_;
};

}
}

// Interface: presentation/fullscreen_strip_geometry.cppm
export {
namespace telar::gui {

struct FullscreenEntryMeasure {
  float index = 0;
  float name = 0;
  bool focused = false;
  bool attention = false;
};

struct FullscreenStripMetrics {
  float ratio = 1;
  float maximum_band_height = 0;
  float mark_side = 0;
};

struct FullscreenStripMeasurements {
  float chip = 0;
  float progress = 0;
  float compact_progress = 0;
};

struct FullscreenStripGeometry {
  static constexpr float entry_gap = 16;
  static constexpr float part_gap = 6;
  static constexpr float chip_gap = 8;
  static constexpr float leave_width = 22;
  static constexpr float margin = 8;
  static constexpr float minimum_entry_room = 48;
  static constexpr float attention_gap = 6;
  static constexpr float attention_diameter = 6;

  struct Entry {
    std::size_t source = 0;
    Rect bounds;
    Rect mark;
    Rect index;
    Rect name;
    Rect attention;
  };

  std::array<Entry, PaneLayout::maximum_panes> entries{};
  std::size_t count = 0;
  Rect leave;
  Rect progress;
  Rect chip;
  bool named = true;
  bool compact_progress = false;

  [[nodiscard]] inline static FullscreenStripGeometry derive(Rect row, const FullscreenStripMetrics &metrics, std::span<const FullscreenEntryMeasure> sizes, const FullscreenStripMeasurements &measurements) noexcept {
    FullscreenStripGeometry result;
    const auto height = std::min(row.height, metrics.maximum_band_height);
    if (height <= 0 || row.width <= 0 || sizes.empty() || sizes.size() > PaneLayout::maximum_panes) {
      return result;
    }

    const auto ratio = metrics.ratio;
    Rect band{.x = row.x + (margin * ratio), .y = row.y + std::floor((row.height - height) / 2), .width = std::max(0.0F, row.width - (2 * margin * ratio)), .height = height};
    const auto control_width = std::min(band.width, leave_width * ratio);
    if (control_width > 0) {
      result.leave = {.x = band.right() - control_width, .y = band.y, .width = control_width, .height = height};
      band.width = std::max(0.0F, band.width - (control_width + (part_gap * ratio)));
    }

    auto progress_width = measurements.progress;
    if (progress_width > band.width / 2) {
      result.compact_progress = true;
      progress_width = measurements.compact_progress;
    }

    if (progress_width > 0 && progress_width + ((part_gap + minimum_entry_room) * ratio) <= band.width) {
      result.progress = {.x = band.right() - progress_width, .y = band.y, .width = progress_width, .height = height};
      band.width = std::max(0.0F, band.width - (progress_width + (part_gap * ratio)));
    }

    std::array<float, PaneLayout::maximum_panes> widths{};
    std::size_t focus = 0;
    const auto gap = entry_gap * ratio;
    auto total = gap * static_cast<float>(sizes.size() - 1);
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      widths[index] = entryWidth(sizes[index], metrics, measurements.chip, true);
      total += widths[index];
      if (sizes[index].focused) {
        focus = index;
      }
    }

    result.named = total <= band.width;
    if (!result.named) {
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        widths[index] = entryWidth(sizes[index], metrics, measurements.chip, false);
      }
    }

    auto first = focus;
    auto used = std::min(widths[first], band.width);
    while (first > 0) {
      const auto required = widths[first - 1] + gap;
      if (required > band.width - used) {
        break;
      }

      --first;
      used += required;
    }

    auto x = band.x;
    for (auto index = first; index < sizes.size(); ++index) {
      if (index != first) {
        x += gap;
      }

      const auto width = std::min(widths[index], std::max(0.0F, band.right() - x));
      if (width <= 0) {
        break;
      }

      auto &entry = result.entries[result.count++];
      entry.source = index;
      entry.bounds = {.x = x, .y = band.y, .width = width, .height = height};
      const auto advance = placeEntry(entry, sizes[index], metrics, result.named);
      if (sizes[index].focused && measurements.chip > 0) {
        const auto chip_x = std::min(band.right(), x + advance + (chip_gap * ratio));
        result.chip = {.x = chip_x, .y = band.y, .width = std::max(0.0F, std::min(measurements.chip, x + width - chip_x)), .height = height};
      }

      x += width;
    }

    return result;
  }

private:
  [[nodiscard]] inline static float entryWidth(const FullscreenEntryMeasure &size, const FullscreenStripMetrics &metrics, float chip_width, bool named) noexcept {
    auto width = metrics.mark_side + (part_gap * metrics.ratio) + size.index;
    if (named || size.focused) {
      width += (part_gap * metrics.ratio) + size.name;
    }

    if (size.attention) {
      width += (attention_gap + attention_diameter) * metrics.ratio;
    }

    if (size.focused && chip_width > 0) {
      width += (chip_gap * metrics.ratio) + chip_width;
    }

    return width;
  }

  [[nodiscard]] inline static float placeEntry(Entry &entry, const FullscreenEntryMeasure &size, const FullscreenStripMetrics &metrics, bool named) noexcept {
    const auto &bounds = entry.bounds;
    const auto end = bounds.right();
    const auto ratio = metrics.ratio;
    const auto side = metrics.mark_side;
    entry.mark = {.x = bounds.x, .y = bounds.y + ((bounds.height - side) / 2), .width = std::max(0.0F, std::min(side, bounds.width)), .height = side};
    auto x = bounds.x + side + (part_gap * ratio);
    entry.index = {.x = x, .y = bounds.y, .width = std::max(0.0F, end - x), .height = bounds.height};
    x += std::min(entry.index.width, size.index);
    if (named || size.focused) {
      x += part_gap * ratio;
      entry.name = {.x = x, .y = bounds.y, .width = std::max(0.0F, end - x), .height = bounds.height};
      x += std::min(entry.name.width, size.name);
    }

    if (size.attention) {
      const auto diameter = attention_diameter * ratio;
      if (x + (((2 * attention_gap) + attention_diameter) * ratio) <= end) {
        entry.attention = {.x = x + (attention_gap * ratio), .y = bounds.y + std::max(0.0F, (bounds.height - diameter) / 2), .width = diameter, .height = std::min(diameter, bounds.height)};
      }

      x += (attention_gap + attention_diameter) * ratio;
    }

    return std::min(x, end) - bounds.x;
  }
};

}
}

// Interface: presentation/tab_motion_frame.cppm
export {
namespace telar::gui {
struct TabMotionFrame {
  static constexpr std::uint64_t default_interval_ns = 16'666'667;
  std::uint64_t now_ns = 0;
  std::uint64_t interval_ns = default_interval_ns;
  std::optional<std::uint64_t> deadline_ns;

  inline void begin(std::uint64_t timestamp) noexcept {
    now_ns = std::max(now_ns, timestamp);
    deadline_ns.reset();
  }

  inline void request(std::uint64_t started, std::uint64_t duration) noexcept {
    std::uint64_t next = 0;
    if (now_ns < started) {
      next = started;
    } else if (duration != 0 && now_ns - started < duration) {
      next = std::min(add(now_ns, interval_ns), add(started, duration));
    } else {
      return;
    }
    if (!deadline_ns || next < *deadline_ns) {
      deadline_ns = next;
    }
  }

private:
  inline static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }
};
}
}

// Interface: presentation/pane_motions.cppm
export {
namespace telar::gui {

struct PaneMotionSlot {
  std::uint64_t id = 0;
  Rect bounds;
};

// Layout targets are committed once. Only presentation rectangles move.
class PaneMotions {
public:
  static constexpr std::uint64_t opening_ns = 180'000'000;
  static constexpr std::uint64_t closing_ns = 150'000'000;

  inline void update(std::span<const PaneMotionSlot> placements, std::uint64_t now_ns, bool immediate = false) noexcept {
    if (placements.size() > entries_.size()) {
      count_ = 0;
      return;
    }

    bool shared = false;
    bool unchanged = placements.size() == count_;
    for (const auto &slot : placements) {
      const auto *old = find(slot.id);
      shared |= old != nullptr;
      unchanged &= old != nullptr && old->to == slot.bounds;
    }
    if (unchanged && !immediate) {
      return;
    }

    const bool animate = !immediate && shared && placements.size() != count_;
    const auto duration = placements.size() > count_ ? opening_ns : closing_ns;
    std::array<Motion, PaneLayout::maximum_panes> next;
    for (std::size_t index = 0; index < placements.size(); ++index) {
      const auto &slot = placements[index];
      const auto *old = find(slot.id);
      auto from = slot.bounds;
      if (animate) {
        from = old != nullptr ? old->value(now_ns) : entrance(slot.bounds);
      }
      next[index] = {.id = slot.id, .from = from, .to = slot.bounds, .started = now_ns, .duration = from == slot.bounds ? 0 : duration};
    }
    std::copy_n(next.begin(), placements.size(), entries_.begin());
    count_ = placements.size();
  }

  [[nodiscard]] inline Rect place(std::size_t index, TabMotionFrame &frame) const noexcept {
    const auto &entry = entries_[index];
    frame.request(entry.started, entry.duration);
    return entry.value(frame.now_ns);
  }

private:
  struct Motion {
    std::uint64_t id = 0;
    Rect from;
    Rect to;
    std::uint64_t started = 0;
    std::uint64_t duration = 0;

    [[nodiscard]] inline Rect value(std::uint64_t now_ns) const noexcept {
      if (duration == 0 || (now_ns >= started && now_ns - started >= duration)) {
        return to;
      }
      const float phase = now_ns <= started ? 0 : static_cast<float>(now_ns - started) / static_cast<float>(duration);
      const float remaining = 1 - phase;
      const float eased = 1 - remaining * remaining * remaining;
      return {.x = from.x + (to.x - from.x) * eased, .y = from.y + (to.y - from.y) * eased, .width = from.width + (to.width - from.width) * eased, .height = from.height + (to.height - from.height) * eased};
    }
  };

  [[nodiscard]] inline const Motion *find(std::uint64_t id) const noexcept {
    const auto entries = std::span{entries_}.first(count_);
    const auto found = std::ranges::find(entries, id, &Motion::id);
    return found == entries.end() ? nullptr : &*found;
  }

  [[nodiscard]] inline Rect entrance(Rect target) const noexcept {
    // The added leaf occupies part of its previous parent. Reveal it from
    // the far edge while the surviving leaf moves the shared divider.
    const Motion *parent = nullptr;
    float best_overlap = 0;
    for (const auto &entry : std::span{entries_}.first(count_)) {
      const auto &bounds = entry.to;
      const auto overlap = bounds.intersect(target);
      if (overlap.width * overlap.height > best_overlap) {
        best_overlap = overlap.width * overlap.height;
        parent = &entry;
      }
    }
    if (parent == nullptr) {
      return target;
    }
    const auto &bounds = parent->to;
    if (target.width / bounds.width < target.height / bounds.height) {
      target.x = target.right();
      target.width = 0;
    } else {
      target.y = target.bottom();
      target.height = 0;
    }
    return target;
  }

  std::array<Motion, PaneLayout::maximum_panes> entries_{};
  std::size_t count_ = 0;
};

}
}

// Interface: presentation/tab_strip_geometry.cppm
export {
namespace telar::gui {

struct TabStripGeometry {
  static constexpr std::size_t maximum_tabs = 64;
  static constexpr std::size_t cap_iterations = 24;
  static constexpr float pill_height = 30;
  static constexpr float pill_radius = pill_height / 2;
  static constexpr float leading = 8;
  static constexpr float trailing = 12;
  static constexpr float spacing = 8;
  static constexpr float chip_side = 20;
  static constexpr float chip_radius = 6;
  static constexpr float chip_alpha = 0.06F;
  static constexpr float selected_chip_alpha = 0.1F;
  static constexpr float mark_side = 14;
  static constexpr float gap = 2;
  static constexpr float control_gap = 8;
  static constexpr float inactive_maximum = 220;
  static constexpr float selected_maximum = 300;
  static constexpr float selected_share = 0.55F;
  static constexpr float caption_minimum = 56;
  static constexpr float counter_width = 36;
  static constexpr float fade_width = 20;
  static constexpr float plus_side = 30;

  enum class Fit : std::uint8_t { full, truncated, compact };

  struct Metrics {
    float leading;
    float trailing;
    float spacing;
    float gap;
    float inactive_maximum;
    float selected_maximum;
    float caption_minimum;
    float counter;

    [[nodiscard]] inline static Metrics scaled(float ratio) noexcept {
      return {
          .leading = TabStripGeometry::leading * ratio,
          .trailing = TabStripGeometry::trailing * ratio,
          .spacing = TabStripGeometry::spacing * ratio,
          .gap = TabStripGeometry::gap * ratio,
          .inactive_maximum = TabStripGeometry::inactive_maximum * ratio,
          .selected_maximum = TabStripGeometry::selected_maximum * ratio,
          .caption_minimum = TabStripGeometry::caption_minimum * ratio,
          .counter = TabStripGeometry::counter_width * ratio,
      };
    }
  };

  struct Measure {
    float caption = 0;
    float chip = 0;
    float status = 0;

    [[nodiscard]] inline float statusSpace(const Metrics &metrics) const noexcept {
      return status > 0 ? metrics.spacing + status : 0;
    }

    [[nodiscard]] inline float whole(const Metrics &metrics) const noexcept {
      return metrics.leading + chip + metrics.spacing + caption + statusSpace(metrics) + metrics.trailing;
    }

    [[nodiscard]] inline float truncated(const Metrics &metrics) const noexcept {
      return std::min(whole(metrics), metrics.leading + chip + metrics.spacing + metrics.caption_minimum + statusSpace(metrics) + metrics.trailing);
    }

    [[nodiscard]] inline float compact(const Metrics &metrics) const noexcept {
      return (2 * metrics.leading) + chip + statusSpace(metrics);
    }
  };

  struct Room {
    float width;
    Metrics metrics;
  };

  struct Plan {
    std::array<float, maximum_tabs> widths{};
    std::array<Fit, maximum_tabs> fits{};
    std::size_t first = 0;
    std::size_t end = 0;
    std::size_t focus = 0;
    std::size_t count = 0;

    [[nodiscard]] inline std::size_t hidden() const noexcept {
      return count - (end - first);
    }

    [[nodiscard]] inline bool shows(std::size_t index) const noexcept {
      return index >= first && index < end;
    }

    [[nodiscard]] inline std::optional<std::size_t> nearestHidden() const noexcept {
      if (hidden() == 0) {
        return std::nullopt;
      }

      const auto left = first > 0 ? focus - (first - 1) : std::numeric_limits<std::size_t>::max();
      const auto right = end < count ? end - focus : std::numeric_limits<std::size_t>::max();

      return left <= right ? first - 1 : end;
    }

    [[nodiscard]] inline float footprint(const Metrics &metrics) const noexcept {
      if (first == end) {
        return 0;
      }

      float used = 0;
      for (auto index = first; index < end; ++index) {
        used += widths[index];
      }

      const auto gaps = metrics.gap * static_cast<float>(end - first - 1);
      used += gaps;
      if (hidden() != 0) {
        used += metrics.gap + metrics.counter;
      }

      return used;
    }
  };

  [[nodiscard]] inline static Plan arrange(std::span<const Measure> sizes, std::size_t focus, const Room &room) noexcept {
    if (sizes.empty() || sizes.size() > maximum_tabs || focus >= sizes.size() || !std::isfinite(room.width) || room.width < 0) {
      return {};
    }

    const auto &metrics = room.metrics;
    Plan result{.first = 0, .end = sizes.size(), .focus = focus, .count = sizes.size()};
    naturalWidths(result, sizes, metrics);
    if (result.footprint(metrics) <= room.width) {
      return result;
    }

    const auto gaps = metrics.gap * static_cast<float>(sizes.size() - 1);
    float natural = 0;
    float shortest = 0;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index == focus) {
        continue;
      }

      natural += std::min(sizes[index].whole(metrics), metrics.inactive_maximum);
      shortest += std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
    }

    const auto whole = sizes[focus].whole(metrics);
    const auto share = sizes.size() == 1 ? room.width : room.width * selected_share;
    auto width = std::max(sizes[focus].compact(metrics), std::min({whole, metrics.selected_maximum, share}));
    const auto minimum = std::min(sizes[focus].truncated(metrics), metrics.selected_maximum);
    const auto caption_room = room.width - gaps - shortest;
    if (caption_room >= minimum) {
      // Preserve every caption before giving extra room to the focused tab.
      width = std::clamp(width, minimum, caption_room);
    }
    result.widths[focus] = width;
    result.fits[focus] = width >= whole ? Fit::full : Fit::truncated;
    const auto budget = room.width - width - gaps;
    if (natural <= budget) {
      return result;
    }

    const auto captioned = captionedTabs(sizes, focus, metrics, budget, shortest <= budget);
    distribute(result, sizes, captioned, metrics, budget);
    if (shortest > budget) {
      while (result.footprint(metrics) > room.width && result.end - result.first > 1) {
        if (result.end - 1 - focus >= focus - result.first) {
          --result.end;
        } else {
          ++result.first;
        }
      }
    }

    return result;
  }

private:
  using Captioned = std::array<bool, maximum_tabs>;

  inline static void naturalWidths(Plan &plan, std::span<const Measure> sizes, const Metrics &metrics) noexcept {
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      const auto maximum = index == plan.focus ? metrics.selected_maximum : metrics.inactive_maximum;
      plan.widths[index] = std::min(sizes[index].whole(metrics), maximum);
      plan.fits[index] = sizes[index].whole(metrics) <= maximum ? Fit::full : Fit::truncated;
    }
  }

  [[nodiscard]] inline static Captioned captionedTabs(std::span<const Measure> sizes, std::size_t focus, const Metrics &metrics, float budget, bool all_fit) noexcept {
    Captioned captioned{};
    if (all_fit) {
      captioned.fill(true);
      captioned[focus] = false;

      return captioned;
    }

    float used = 0;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != focus) {
        used += sizes[index].compact(metrics);
      }
    }

    for (std::size_t distance = 1; distance < sizes.size(); ++distance) {
      const std::array<std::optional<std::size_t>, 2> candidates{focus >= distance ? std::optional{focus - distance} : std::nullopt, focus + distance < sizes.size() ? std::optional{focus + distance} : std::nullopt};
      for (const auto candidate : candidates) {
        if (!candidate) {
          continue;
        }

        const auto index = *candidate;
        const auto extra = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum) - sizes[index].compact(metrics);
        if (used + extra <= budget) {
          captioned[index] = true;
          used += extra;
        }
      }
    }

    return captioned;
  }

  [[nodiscard]] inline static float largestCap(std::span<const Measure> sizes, const Captioned &captioned, const Metrics &metrics, float budget) noexcept {
    float low = 0;
    auto high = metrics.inactive_maximum;
    for (std::size_t iteration = 0; iteration < cap_iterations; ++iteration) {
      const auto cap = (low + high) / 2;
      float used = 0;
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        if (captioned[index]) {
          used += std::max(std::min(sizes[index].truncated(metrics), metrics.inactive_maximum), std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap}));
        }
      }

      if (used <= budget) {
        low = cap;
      } else {
        high = cap;
      }
    }

    return low;
  }

  inline static void distribute(Plan &plan, std::span<const Measure> sizes, const Captioned &captioned, const Metrics &metrics, float budget) noexcept {
    float fixed = 0;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != plan.focus && !captioned[index]) {
        plan.widths[index] = sizes[index].compact(metrics);
        plan.fits[index] = Fit::compact;
        fixed += sizes[index].compact(metrics);
      }
    }

    const auto cap = largestCap(sizes, captioned, metrics, budget - fixed);
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (captioned[index]) {
        const auto minimum = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
        const auto width = std::floor(std::max(minimum, std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap})));
        plan.widths[index] = width;
        plan.fits[index] = width >= sizes[index].whole(metrics) ? Fit::full : Fit::truncated;
      }
    }
  }
};

}
}

// Interface: presentation/tab_motions.cppm
export {
namespace telar::gui {

struct TabMotionSlot {
  std::uint64_t id = 0;
  Rect bounds;
  bool immediate = false;
};

struct TabMotion {
  static constexpr std::uint64_t duration_ns = 180'000'000;
  std::uint64_t id = 0;
  Rect from;
  Rect to;
  std::uint64_t started = 0;
  std::uint64_t duration = 0;
  bool seen = true;

  [[nodiscard]] inline Rect value(std::uint64_t now_ns) const noexcept {
    float progress = 1;
    if (now_ns < started) {
      progress = 0;
    } else if (duration != 0 && now_ns - started < duration) {
      progress = static_cast<float>(now_ns - started) / static_cast<float>(duration);
    }
    const float remaining = 1 - progress;
    const float eased = 1 - (remaining * remaining * remaining);

    return {.x = from.x + ((to.x - from.x) * eased), .y = from.y + ((to.y - from.y) * eased), .width = from.width + ((to.width - from.width) * eased), .height = from.height + ((to.height - from.height) * eased)};
  }

  [[nodiscard]] inline Rect place(Rect bounds, TabMotionFrame &frame, bool immediate = false) noexcept {
    if (immediate) {
      from = bounds;
      to = bounds;
      duration = 0;
      return bounds;
    }
    if (to != bounds) {
      from = value(frame.now_ns);
      to = bounds;
      started = frame.now_ns;
      duration = duration_ns;
    }
    frame.request(started, duration);
    return value(frame.now_ns);
  }
};

class TabMotions {
public:
  static constexpr std::uint64_t duration_ns = TabMotion::duration_ns;

  inline void begin(std::optional<WorkspaceLocation> workspace) noexcept {
    if (workspace_.has_value() != workspace.has_value() || (workspace_ && (workspace_->kind != workspace->kind || workspace_->id != workspace->id))) {
      count_ = 0;
      workspace_ = workspace;
    }
    for (auto &motion : std::span{entries_}.first(count_)) {
      motion.seen = false;
    }
  }

  [[nodiscard, gnu::always_inline]] inline Rect place(TabMotionSlot slot, TabMotionFrame &frame) noexcept {
    if (slot.immediate && count_ == 1 && entries_[0].id == slot.id) {
      entries_[0].seen = true;
      entries_[0].from = slot.bounds;
      entries_[0].to = slot.bounds;
      entries_[0].duration = 0;
      return slot.bounds;
    }
    for (auto &motion : std::span{entries_}.first(count_)) {
      if (motion.id != slot.id) {
        continue;
      }

      motion.seen = true;
      return motion.place(slot.bounds, frame, slot.immediate);
    }

    if (count_ < entries_.size()) {
      entries_[count_++] = {.id = slot.id, .from = slot.bounds, .to = slot.bounds, .started = frame.now_ns};
    }

    return slot.bounds;
  }

  inline void finish() noexcept {
    if (count_ == 1 && entries_[0].seen) {
      return;
    }
    std::size_t kept = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &motion = entries_[index];
      if (motion.seen) {
        if (kept != index) {
          entries_[kept] = motion;
        }
        ++kept;
      }
    }
    count_ = kept;
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return count_;
  }

private:
  std::array<TabMotion, TabStripGeometry::maximum_tabs> entries_{};
  std::size_t count_ = 0;
  std::optional<WorkspaceLocation> workspace_;
};

}
}
