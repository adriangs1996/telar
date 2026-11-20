module telar.gui.features.history;

import std;

import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::history {

  bool HistoryActionTarget::contains(HistoryActionPosition position) const noexcept {
    return position.x >= static_cast<double>(bounds.x) && position.y >= static_cast<double>(bounds.y) && position.x < static_cast<double>(bounds.x) + static_cast<double>(bounds.width) && position.y < static_cast<double>(bounds.y) + static_cast<double>(bounds.height);
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

  ds::Option<HistoryCardAction> HistoryActionCapture::release(const HistoryActionSurface& surface, HistoryActionPosition position) noexcept {
    present(surface);
    held_ = false;
    const auto action = std::exchange(action_, ds::none);
    const auto* target = action ? surface.find(*action) : nullptr;

    return target != nullptr && target->contains(position) ? action : ds::none;
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
    return position.x >= static_cast<double>(bounds.x) && position.y >= static_cast<double>(bounds.y) && position.x < static_cast<double>(bounds.x) + static_cast<double>(bounds.width) && position.y < static_cast<double>(bounds.y) + static_cast<double>(bounds.height);
  }

  const ds::Option<HistoryHoverIdentity>& HistoryHover::hovered() const noexcept {
    return hovered_;
  }

  bool HistoryHover::cancel() noexcept {
    const bool changed = hovered_.hasValue();

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

    ds::Option<HistoryHoverIdentity> next;

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

  std::int32_t HistoryScroll::consume(HistoryScrollState state, const HistoryScrollSurface& surface, HistoryScrollPosition pointer, ScrollSample sample) noexcept {
    if (!state.ready) {
      wheel_.reset();

      return 0;
    }

    if (!surface.delivered || surface.generation != state.generation || (surface.has_rows && surface.revision != state.revision) || !within(surface.bounds, pointer)) {
      return 0;
    }

    if (generation_ != state.generation || inspecting_ != state.inspecting) {
      wheel_.reset();
      generation_ = state.generation;
      inspecting_ = state.inspecting;
    }

    sample.cell_height = state.inspecting || !surface.has_rows ? surface.cell_height : surface.row_height;

    return wheel_.consume(sample);
  }

  bool HistoryScroll::within(Rect bounds, HistoryScrollPosition pointer) noexcept {
    return pointer.x >= static_cast<double>(bounds.x) && pointer.y >= static_cast<double>(bounds.y) && pointer.x < static_cast<double>(bounds.x) + static_cast<double>(bounds.width) && pointer.y < static_cast<double>(bounds.y) + static_cast<double>(bounds.height);
  }

}
