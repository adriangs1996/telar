#pragma once

#include "application/pane_layout.hpp"
#include "core/configuration.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace telar::gui {

class FramePacer {
public:
  struct Pane {
    std::uint64_t pane_id = 0;
    std::uint64_t frame_id = 0;
    bool attached = false;
    std::uint64_t attachment_generation = 0;
  };

  static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
  static constexpr std::uint64_t default_interval_ns = nanoseconds_per_second / Configuration::default_fps;
  static constexpr std::uint64_t minimum_interval_ns = nanoseconds_per_second / Configuration::maximum_fps;
  static constexpr std::uint64_t maximum_interval_ns = nanoseconds_per_second / Configuration::minimum_fps;
  static constexpr std::uint64_t input_grace_ns = 30'000'000;
  static constexpr std::uint32_t input_frame_budget = 16;
  static constexpr std::size_t capacity = PaneLayout::maximum_panes;

  [[nodiscard]] static std::uint64_t resolveInterval(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept {
    const auto cap_interval_ns = maximum_fps ? nanoseconds_per_second / std::max<std::uint16_t>(*maximum_fps, 1) : 0;

    return std::clamp(std::max(display_interval_ns, cap_interval_ns), minimum_interval_ns, maximum_interval_ns);
  }

  std::uint64_t configure(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept {
    interval_ns_ = resolveInterval(display_interval_ns, maximum_fps);

    return interval_ns_;
  }

  [[nodiscard]] std::uint64_t interval() const noexcept {
    return interval_ns_;
  }

  void noteInput(Pane pane, std::uint64_t now_ns) noexcept {
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

  [[nodiscard]] std::optional<std::uint64_t> waitUntil(std::span<const Pane> panes, std::uint64_t now_ns) const noexcept {
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

  void record(std::span<const Pane> panes, std::uint64_t now_ns) noexcept {
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
  }

private:
  struct InputGrace {
    Pane pane;
    std::uint64_t started_ns;
    std::uint32_t frames_left = input_frame_budget;

    [[nodiscard]] bool includes(Pane candidate) const noexcept {
      return candidate.attached && candidate.pane_id == pane.pane_id && candidate.attachment_generation == pane.attachment_generation && candidate.frame_id > pane.frame_id;
    }

    [[nodiscard]] bool rejects(Pane candidate, std::uint64_t now_ns) const noexcept {
      return pane.attachment_generation > candidate.attachment_generation || now_ns < started_ns || (pane.attachment_generation == candidate.attachment_generation && pane.frame_id > candidate.frame_id);
    }

    [[nodiscard]] bool active(std::uint64_t now_ns) const noexcept {
      return now_ns >= started_ns && now_ns - started_ns < input_grace_ns && frames_left != 0;
    }
  };

  [[nodiscard]] static std::uint64_t after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, interval_ns);
  }

  [[nodiscard]] bool ordinaryAvailable(std::uint64_t now_ns) const noexcept {
    return !anchor_ns_ || (now_ns >= *anchor_ns_ && now_ns - *anchor_ns_ >= interval_ns_);
  }

  std::array<std::optional<InputGrace>, capacity> inputs_{};
  std::uint64_t interval_ns_ = default_interval_ns;
  std::optional<std::uint64_t> anchor_ns_;
};

}
