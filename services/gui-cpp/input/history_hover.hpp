#pragma once

#include "core/geometry.hpp"
#include "history/choice.hpp"
#include "input/history_action_capture.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_footer.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <variant>

namespace telar::gui {

enum class HistoryFilterAction : std::uint8_t {
  global,
  workspace,
  cwd,
  pane,
  human,
  agent,
  all,
  failed,
};

inline constexpr std::size_t history_filter_target_count = 8;

struct HistoryFooterIdentity {
  HistoryFooterAction action = HistoryFooterAction::none;
  HistoryChoice choice;

  [[nodiscard]] bool submission() const noexcept {
    return action == HistoryFooterAction::submit || action == HistoryFooterAction::alternate;
  }

  bool operator==(const HistoryFooterIdentity &other) const noexcept {
    return action == other.action && (!submission() || choice == other.choice);
  }
};

struct HistoryHoverIdentity {
  std::variant<HistoryChoice, HistoryCardAction, HistoryFooterIdentity, HistoryFilterAction> action;
  std::uint64_t generation = 0;

  bool operator==(const HistoryHoverIdentity &other) const noexcept {
    if (generation != other.generation) {
      return false;
    }

    if (const auto *row = std::get_if<HistoryChoice>(&action)) {
      const auto *other_row = std::get_if<HistoryChoice>(&other.action);

      return other_row != nullptr && *row == *other_row;
    }

    const auto *card = std::get_if<HistoryCardAction>(&action);
    const auto *other_card = std::get_if<HistoryCardAction>(&other.action);

    if (card != nullptr) {
      return other_card != nullptr && *card == *other_card;
    }

    const auto *footer = std::get_if<HistoryFooterIdentity>(&action);
    const auto *other_footer = std::get_if<HistoryFooterIdentity>(&other.action);

    if (footer != nullptr) {
      return other_footer != nullptr && *footer == *other_footer;
    }

    const auto *filter = std::get_if<HistoryFilterAction>(&action);
    const auto *other_filter = std::get_if<HistoryFilterAction>(&other.action);

    return filter != nullptr && other_filter != nullptr && *filter == *other_filter;
  }
};

struct HistoryHoverTarget {
  HistoryHoverIdentity identity;
  Rect bounds{};

  [[nodiscard]] bool contains(HistoryActionPosition position) const noexcept {
    return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
  }
};

class HistoryHover {
public:
  enum class Observation : std::uint8_t {
    point,
    retained,
    leave,
  };

  [[nodiscard]] const std::optional<HistoryHoverIdentity> &hovered() const noexcept { return hovered_; }

  bool cancel() noexcept {
    const bool changed = hovered_.has_value();
    hovered_.reset();

    return changed;
  }

  bool present(std::span<const HistoryHoverTarget> targets) noexcept {
    if (hovered_ && std::ranges::none_of(targets, [&](const HistoryHoverTarget &target) { return target.identity == *hovered_ && !target.bounds.empty(); })) {
      return cancel();
    }

    return false;
  }

  bool observe(std::span<const HistoryHoverTarget> targets, HistoryActionPosition position, Observation observation) noexcept {
    if (observation == Observation::retained) {
      return false;
    }

    std::optional<HistoryHoverIdentity> next;
    if (observation == Observation::point) {
      for (auto index = targets.size(); index > 0; --index) {
        const auto &target = targets[index - 1];
        if (!target.bounds.empty() && target.contains(position)) {
          next = target.identity;
          break;
        }
      }
    }

    const bool changed = next != hovered_;
    hovered_ = next;

    return changed;
  }

private:
  std::optional<HistoryHoverIdentity> hovered_;
};

}
