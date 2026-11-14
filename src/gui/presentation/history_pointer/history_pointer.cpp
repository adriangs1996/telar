module telar.gui.presentation.history_pointer;

import std;

namespace telar::gui {

  bool HistoryActionTarget::contains(HistoryActionPosition position) const noexcept {
    return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
  }

  const HistoryActionTarget* HistoryActionSurface::find(HistoryCardAction action) const noexcept {
    for (const auto& target : targets) {
      if (target.action == action && !target.bounds.empty()) {
        return &target;
      }
    }

    return nullptr;
  }

  bool HistoryActionCapture::begin(const HistoryActionSurface& surface, HistoryActionPosition position, bool primary) noexcept {
    *this = {};
    for (std::size_t index = surface.targets.size(); index > 0; --index) {
      const auto& target = surface.targets[index - 1];
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

  bool HistoryActionCapture::held() const noexcept {
    return held_;
  }

  void HistoryActionCapture::cancel() noexcept {
    action_.reset();
  }

  void HistoryActionCapture::present(const HistoryActionSurface& surface) noexcept {
    const auto* target = action_ ? surface.find(*action_) : nullptr;
    if (surface.generation != generation_ || surface.choice != choice_ || target == nullptr || !target->enabled) {
      cancel();
    }
  }

  std::optional<HistoryCardAction> HistoryActionCapture::release(const HistoryActionSurface& surface, HistoryActionPosition position) noexcept {
    present(surface);
    held_ = false;
    const auto action = std::exchange(action_, std::nullopt);
    const auto* target = action ? surface.find(*action) : nullptr;

    return target != nullptr && target->contains(position) ? action : std::nullopt;
  }

  bool HistoryFooterIdentity::submission() const noexcept {
    return action == HistoryFooterAction::submit || action == HistoryFooterAction::alternate;
  }

  bool HistoryFooterIdentity::operator==(const HistoryFooterIdentity& other) const noexcept {
    return action == other.action && (!submission() || choice == other.choice);
  }

  bool HistoryInspectionIdentity::submission() const noexcept {
    return action == HistoryInspectionAction::submit || action == HistoryInspectionAction::alternate;
  }

  bool HistoryInspectionIdentity::operator==(const HistoryInspectionIdentity& other) const noexcept {
    return action == other.action && (!submission() || choice == other.choice);
  }

  bool HistoryHoverIdentity::operator==(const HistoryHoverIdentity& other) const noexcept {
    if (generation != other.generation) {
      return false;
    }

    if (const auto* row = std::get_if<HistoryChoice>(&action)) {
      const auto* other_row = std::get_if<HistoryChoice>(&other.action);

      return other_row != nullptr && *row == *other_row;
    }

    const auto* card = std::get_if<HistoryCardAction>(&action);
    const auto* other_card = std::get_if<HistoryCardAction>(&other.action);

    if (card != nullptr) {
      return other_card != nullptr && *card == *other_card;
    }

    const auto* footer = std::get_if<HistoryFooterIdentity>(&action);
    const auto* other_footer = std::get_if<HistoryFooterIdentity>(&other.action);

    if (footer != nullptr) {
      return other_footer != nullptr && *footer == *other_footer;
    }

    const auto* filter = std::get_if<HistoryFilterAction>(&action);
    const auto* other_filter = std::get_if<HistoryFilterAction>(&other.action);

    if (filter != nullptr) {
      return other_filter != nullptr && *filter == *other_filter;
    }

    const auto* inspection = std::get_if<HistoryInspectionIdentity>(&action);
    const auto* other_inspection = std::get_if<HistoryInspectionIdentity>(&other.action);

    return inspection != nullptr && other_inspection != nullptr && *inspection == *other_inspection;
  }

  bool HistoryHoverTarget::contains(HistoryActionPosition position) const noexcept {
    return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
  }

  const std::optional<HistoryHoverIdentity>& HistoryHover::hovered() const noexcept {
    return hovered_;
  }

  bool HistoryHover::cancel() noexcept {
    const bool changed = hovered_.has_value();

    hovered_.reset();

    return changed;
  }

  bool HistoryHover::present(std::span<const HistoryHoverTarget> targets) noexcept {
    if (hovered_ && std::ranges::none_of(targets, [&](const HistoryHoverTarget& target) {
          return target.identity == *hovered_ && !target.bounds.empty();
        })) {
      return cancel();
    }

    return false;
  }

  bool HistoryHover::observe(std::span<const HistoryHoverTarget> targets, HistoryActionPosition position, Observation observation) noexcept {
    if (observation == Observation::retained) {
      return false;
    }

    std::optional<HistoryHoverIdentity> next;

    if (observation == Observation::point) {
      for (auto index = targets.size(); index > 0; --index) {
        const auto& target = targets[index - 1];
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

}
