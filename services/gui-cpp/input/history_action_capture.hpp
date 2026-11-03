#pragma once

#include "core/geometry.hpp"
#include "history/choice.hpp"
#include "presentation/history_actions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>

namespace telar::gui {

struct HistoryActionPosition {
  double x = 0;
  double y = 0;
};

struct HistoryActionTarget {
  HistoryCardAction action = HistoryCardAction::copy;
  Rect bounds{};
  bool enabled = false;

  [[nodiscard]] bool contains(HistoryActionPosition position) const noexcept {
    return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
  }
};

struct HistoryActionSurface {
  std::array<HistoryActionTarget, HistoryActions::count> targets{};
  std::uint64_t generation = 0;
  double scale = 1;
  std::optional<HistoryChoice> choice;

  [[nodiscard]] const HistoryActionTarget *find(HistoryCardAction action) const noexcept {
    for (const auto &target : targets) {
      if (target.action == action && !target.bounds.empty()) {
        return &target;
      }
    }

    return nullptr;
  }
};

class HistoryActionCapture {
public:
  [[nodiscard]] bool begin(const HistoryActionSurface &surface, HistoryActionPosition position, bool primary) noexcept {
    *this = {};
    for (std::size_t index = surface.targets.size(); index > 0; --index) {
      const auto &target = surface.targets[index - 1];
      if (!target.bounds.empty() && target.contains(position)) {
        held_ = true;
        generation_ = surface.generation;
        choice_ = surface.choice;
        if (primary && target.enabled) {
          action_ = target.action;
        }

        return true;
      }
    }

    return false;
  }

  [[nodiscard]] bool held() const noexcept { return held_; }
  void cancel() noexcept { action_.reset(); }

  void present(const HistoryActionSurface &surface) noexcept {
    const auto *target = action_ ? surface.find(*action_) : nullptr;
    if (surface.generation != generation_ || surface.choice != choice_ || target == nullptr || !target->enabled) {
      cancel();
    }
  }

  [[nodiscard]] std::optional<HistoryCardAction> release(const HistoryActionSurface &surface, HistoryActionPosition position) noexcept {
    present(surface);
    held_ = false;
    const auto action = std::exchange(action_, std::nullopt);
    const auto *target = action ? surface.find(*action) : nullptr;

    return target != nullptr && target->contains(position) ? action : std::nullopt;
  }

private:
  std::optional<HistoryCardAction> action_;
  std::optional<HistoryChoice> choice_;
  std::uint64_t generation_ = 0;
  bool held_ = false;
};

}
