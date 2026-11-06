#pragma once

#include "core/cell_rectangle.hpp"
#include "application/pane_bottom_reservation.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <variant>

namespace telar::gui {

class PaneLayout {
public:
  static constexpr std::size_t maximum_panes = 64;
  static constexpr std::size_t maximum_nodes = (maximum_panes * 2) - 1;
  static constexpr std::uint16_t ratio_maximum = 10000;
  static constexpr std::uint16_t ratio_half = ratio_maximum / 2;
  static constexpr std::uint16_t ratio_minimum = 1000;
  static constexpr std::uint16_t ratio_maximum_split = 9000;
  static constexpr std::uint16_t resize_step = ratio_maximum / 20;

  struct Metrics {
    std::uint8_t border = 1;
    std::uint8_t gap = 1;
    std::uint8_t header = 1;

    [[nodiscard]] std::uint16_t minimumPaneExtent(ClientLayoutAxis axis = ClientLayoutAxis::horizontal) const noexcept {
      return border == 0 ? 1 : 1 + static_cast<std::uint16_t>(border) + (axis == ClientLayoutAxis::vertical ? std::max(border, header) : border);
    }

    [[nodiscard]] CellRectangle content(CellRectangle bounds) const noexcept {
      auto result = bounds.inner(border);
      const auto extra = border != 0 && header > border ? std::min<std::uint16_t>(header - border, result.height) : 0;
      result.y = static_cast<std::uint16_t>(result.y + extra);
      result.height = static_cast<std::uint16_t>(result.height - extra);

      return result;
    }

    bool operator==(const Metrics &) const = default;
  };

  struct Placement {
    std::uint64_t pane_id = 0;
    CellRectangle bounds;
    std::uint16_t display_index = 0;
    CellRectangle content;
    bool framed = false;
  };

  struct Divider {
    std::size_t node_index = 0;
    ClientLayoutAxis axis = ClientLayoutAxis::horizontal;
    CellRectangle bounds;
    CellRectangle parent_bounds;
  };

  struct DividerPosition {
    std::size_t node_index;
    std::uint16_t ratio;
  };

  struct FocusRequest {
    std::uint64_t pane_id = 0;
    PaneDirection direction = PaneDirection::right;
    bool fullscreen = false;
  };

  struct SplitBounds {
    CellRectangle existing_content;
    CellRectangle added_content;
  };

  [[nodiscard]] bool hasBorders(bool fullscreen, Metrics metrics) const noexcept {
    return metrics.border != 0 && (fullscreen || count_ > 1);
  }

  void restore(std::span<const ClientLayoutNode> nodes) {
    if (nodes.size() > nodes_.size()) {
      throw EncodingError{"Pane layout exceeds capacity"};
    }

    std::size_t pending = 1;
    std::size_t panes = 0;
    std::array<std::uint64_t, maximum_panes> identities{};
    for (const auto &node : nodes) {
      if (pending == 0) {
        throw EncodingError{"Trailing pane layout nodes"};
      }

      --pending;
      if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
        if (pane->pane_id == 0 || panes == maximum_panes || std::find(identities.begin(), identities.begin() + panes, pane->pane_id) != identities.begin() + panes) {
          throw EncodingError{"Invalid pane layout identity"};
        }

        identities[panes++] = pane->pane_id;
      } else {
        const auto &split = std::get<ClientLayoutSplit>(node);
        if (split.ratio < ratio_minimum || split.ratio > ratio_maximum_split || (split.axis != ClientLayoutAxis::horizontal && split.axis != ClientLayoutAxis::vertical)) {
          throw EncodingError{"Invalid pane layout ratio"};
        }

        pending += 2;
      }
    }

    if (!nodes.empty() && pending != 0) {
      throw EncodingError{"Incomplete pane layout"};
    }

    std::ranges::copy(nodes, nodes_.begin());
    count_ = nodes.size();
  }

  bool add(std::uint64_t pane_id, ClientLayoutAxis axis, std::uint64_t beside) noexcept {
    if (pane_id == 0 || contains(pane_id) || count_ + 2 > maximum_nodes) {
      return false;
    }

    if (count_ == 0) {
      nodes_[count_++] = ClientLayoutPane{pane_id};

      return true;
    }

    const auto target = indexOf(beside);
    if (!target) {
      return false;
    }

    std::move_backward(nodes_.begin() + *target + 1, nodes_.begin() + count_, nodes_.begin() + count_ + 2);
    nodes_[*target] = ClientLayoutSplit{.axis = axis, .ratio = ratio_half};
    nodes_[*target + 1] = ClientLayoutPane{beside};
    nodes_[*target + 2] = ClientLayoutPane{pane_id};
    count_ += 2;

    return true;
  }

  bool remove(std::uint64_t pane_id) noexcept {
    const auto target = indexOf(pane_id);
    if (!target) {
      return false;
    }

    if (count_ == 1) {
      count_ = 0;

      return true;
    }

    for (std::size_t parent = *target; parent-- > 0;) {
      if (!std::holds_alternative<ClientLayoutSplit>(nodes_[parent])) {
        continue;
      }

      const auto first = parent + 1;
      const auto second = subtreeEnd(first);
      if (first != *target && second != *target) {
        continue;
      }

      const auto survivor = first == *target ? second : first;
      const auto survivor_end = subtreeEnd(survivor);
      const auto parent_end = subtreeEnd(parent);
      std::move(nodes_.begin() + survivor, nodes_.begin() + survivor_end, nodes_.begin() + parent);
      std::move(nodes_.begin() + parent_end, nodes_.begin() + count_, nodes_.begin() + parent_end - 2);
      count_ -= 2;

      return true;
    }

    return false;
  }

  void setBottomReservation(std::optional<PaneBottomReservation> reservation) noexcept {
    reservation_ = reservation;
  }

  [[nodiscard]] CellRectangle reservedArea() const noexcept {
    return reserved_;
  }

  std::span<const Placement> arrange(CellRectangle bounds, Metrics metrics, std::optional<std::uint64_t> fullscreen = {}) noexcept {
    placement_count_ = 0;
    divider_count_ = 0;
    reserved_ = {};
    if (fullscreen && contains(*fullscreen)) {
      placements_[placement_count_++] = {.pane_id = *fullscreen, .bounds = bounds, .display_index = displayIndex(*fullscreen), .content = bounds.inner(metrics.border), .framed = hasBorders(true, metrics)};
    } else if (count_ != 0) {
      arrangeNodes(bounds, metrics);
    }

    reserveBelowPane(metrics);

    return {placements_.data(), placement_count_};
  }

  [[nodiscard]] std::span<const Divider> dividers() const noexcept {
    return {dividers_.data(), divider_count_};
  }

  [[nodiscard]] std::optional<SplitBounds> prospectiveSplit(CellRectangle area, ClientLayoutAxis axis, std::uint64_t pane_id, Metrics metrics, std::optional<std::uint64_t> fullscreen = {}) noexcept {
    if (count_ + 2 > maximum_nodes) {
      return std::nullopt;
    }

    const auto placements = arrange(area, metrics, fullscreen);
    const auto found = std::ranges::find(placements, pane_id, &Placement::pane_id);
    if (found == placements.end()) {
      return std::nullopt;
    }

    const auto minimum_width = metrics.minimumPaneExtent(ClientLayoutAxis::horizontal);
    const auto minimum_height = metrics.minimumPaneExtent(ClientLayoutAxis::vertical);
    const auto bounds = found->bounds;
    const bool enough_space = axis == ClientLayoutAxis::horizontal ? bounds.width >= (2 * minimum_width) + metrics.gap && bounds.height >= minimum_height : bounds.width >= minimum_width && bounds.height >= (2 * minimum_height) + metrics.gap;
    if (!enough_space) {
      return std::nullopt;
    }

    const auto geometry = partition(bounds, {.axis = axis, .ratio = ratio_half}, metrics.gap);

    return SplitBounds{.existing_content = metrics.content(geometry.first), .added_content = metrics.content(geometry.second)};
  }

  bool setSplitRatio(DividerPosition position) noexcept {
    if (position.node_index >= count_) {
      return false;
    }

    auto *split = std::get_if<ClientLayoutSplit>(&nodes_[position.node_index]);
    if (split == nullptr) {
      return false;
    }

    const auto bounded = std::clamp(position.ratio, ratio_minimum, ratio_maximum_split);
    if (bounded == split->ratio) {
      return false;
    }

    split->ratio = bounded;

    return true;
  }

  [[nodiscard]] std::uint64_t focusTarget(CellRectangle area, Metrics metrics, FocusRequest request) noexcept {
    if (request.fullscreen) {
      return fullscreenFocusTarget(request);
    }

    const auto placements = arrange(area, metrics);
    const auto source = std::ranges::find(placements, request.pane_id, &Placement::pane_id);
    if (source == placements.end()) {
      return 0;
    }

    std::uint64_t target = 0;
    auto best_score = std::numeric_limits<std::uint64_t>::max();
    const FocusOrigin origin{.bounds = source->bounds, .direction = request.direction};
    for (const auto &placement : placements) {
      if (placement.pane_id == request.pane_id) {
        continue;
      }

      const auto score = origin.score(placement.bounds);
      if (score && *score < best_score) {
        target = placement.pane_id;
        best_score = *score;
      }
    }

    return target;
  }

  bool resize(std::uint64_t pane_id, PaneDirection direction, CellRectangle area, Metrics metrics) noexcept {
    const auto target = indexOf(pane_id);
    if (!target) {
      return false;
    }

    const auto axis = direction == PaneDirection::left || direction == PaneDirection::right ? ClientLayoutAxis::horizontal : ClientLayoutAxis::vertical;
    const bool decreasing = direction == PaneDirection::left || direction == PaneDirection::up;
    std::optional<std::size_t> fallback;
    for (std::size_t parent = *target; parent-- > 0;) {
      const auto *split = std::get_if<ClientLayoutSplit>(&nodes_[parent]);
      if (split == nullptr || split->axis != axis || subtreeEnd(parent) <= *target) {
        continue;
      }

      const bool in_first = *target < subtreeEnd(parent + 1);
      if (in_first != decreasing) {
        return moveDivider(parent, decreasing, area, metrics);
      }

      if (!fallback) {
        fallback = parent;
      }
    }

    return fallback && moveDivider(*fallback, decreasing, area, metrics);
  }

  [[nodiscard]] bool contains(std::uint64_t pane_id) const noexcept {
    return indexOf(pane_id).has_value();
  }

  [[nodiscard]] std::span<const ClientLayoutNode> nodes() const noexcept {
    return {nodes_.data(), count_};
  }

  [[nodiscard]] std::uint64_t firstPane() const noexcept {
    for (const auto &node : nodes()) {
      if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
        return pane->pane_id;
      }
    }

    return 0;
  }

  [[nodiscard]] std::uint16_t displayIndex(std::uint64_t pane_id) const noexcept {
    std::uint16_t index = 0;
    for (const auto &node : nodes()) {
      if (const auto *leaf = std::get_if<ClientLayoutPane>(&node)) {
        ++index;
        if (leaf->pane_id == pane_id) {
          return index;
        }
      }
    }

    return 0;
  }

private:
  void reserveBelowPane(Metrics metrics) noexcept {
    if (!reservation_) {
      return;
    }

    for (auto &placement : std::span{placements_}.first(placement_count_)) {
      if (placement.pane_id != reservation_->pane_id) {
        continue;
      }

      const auto available = placement.bounds.height > reservation_->minimum_pane_height ? static_cast<std::uint16_t>(placement.bounds.height - reservation_->minimum_pane_height) : std::uint16_t{};
      const auto height = std::min(reservation_->preferred_height, available);
      if (height < reservation_->minimum_height) {
        return;
      }

      const bool borderless = placement.bounds == placement.content;
      reserved_ = placement.bounds;
      placement.bounds.height = static_cast<std::uint16_t>(placement.bounds.height - height);
      reserved_.y = static_cast<std::uint16_t>(static_cast<std::uint32_t>(reserved_.y) + placement.bounds.height);
      reserved_.height = height;
      placement.content = borderless ? placement.bounds : metrics.content(placement.bounds);

      return;
    }
  }

  struct FocusOrigin {
    CellRectangle bounds;
    PaneDirection direction = PaneDirection::right;

    [[nodiscard]] std::optional<std::uint64_t> score(CellRectangle candidate) const noexcept {
      const auto horizontal = direction == PaneDirection::left || direction == PaneDirection::right;
      const auto decreasing = direction == PaneDirection::left || direction == PaneDirection::up;
      const auto source_begin = horizontal ? bounds.x : bounds.y;
      const auto source_end = horizontal ? bounds.right() : bounds.bottom();
      const auto candidate_begin = horizontal ? candidate.x : candidate.y;
      const auto candidate_end = horizontal ? candidate.right() : candidate.bottom();
      const auto forward = decreasing ? candidate_end <= source_begin : candidate_begin >= source_end;
      if (!forward) {
        return std::nullopt;
      }

      const auto primary = decreasing ? source_begin - candidate_end : candidate_begin - source_end;
      const auto source_center = horizontal ? (2U * bounds.y) + bounds.height : (2U * bounds.x) + bounds.width;
      const auto candidate_center = horizontal ? (2U * candidate.y) + candidate.height : (2U * candidate.x) + candidate.width;
      const auto secondary = source_center > candidate_center ? (source_center - candidate_center) / 2 : (candidate_center - source_center) / 2;
      constexpr std::uint64_t primary_weight = 65536;

      return (static_cast<std::uint64_t>(primary) * primary_weight) + secondary;
    }
  };

  bool moveDivider(std::size_t index, bool decreasing, CellRectangle area, Metrics metrics) noexcept {
    const auto *split = std::get_if<ClientLayoutSplit>(&nodes_[index]);
    if (split == nullptr) {
      return false;
    }

    const auto previous_ratio = split->ratio;
    const auto adjusted = decreasing ? previous_ratio - resize_step : previous_ratio + resize_step;

    const auto ratio = static_cast<std::uint16_t>(std::clamp(adjusted, static_cast<int>(ratio_minimum), static_cast<int>(ratio_maximum_split)));
    arrange(area, metrics);
    const auto divider = std::ranges::find(dividers(), index, &Divider::node_index);
    if (divider == dividers().end()) {
      return false;
    }

    const auto proposed = partition(divider->parent_bounds, {.axis = split->axis, .ratio = ratio}, metrics.gap);
    const auto horizontal = split->axis == ClientLayoutAxis::horizontal;
    const auto first_extent = horizontal ? proposed.first.width : proposed.first.height;
    const auto second_extent = horizontal ? proposed.second.width : proposed.second.height;
    const auto second = subtreeEnd(index + 1);
    if (first_extent < minimumExtent(index + 1, split->axis, metrics) || second_extent < minimumExtent(second, split->axis, metrics)) {
      return false;
    }

    return setSplitRatio({.node_index = index, .ratio = ratio});
  }

  [[nodiscard]] std::uint64_t fullscreenFocusTarget(FocusRequest request) const noexcept {
    if (request.direction == PaneDirection::up || request.direction == PaneDirection::down) {
      return 0;
    }

    std::uint64_t previous = 0;
    bool found = false;
    for (const auto &node : nodes()) {
      const auto *pane = std::get_if<ClientLayoutPane>(&node);
      if (pane == nullptr) {
        continue;
      }

      if (pane->pane_id == request.pane_id) {
        if (request.direction == PaneDirection::left) {
          return previous;
        }

        found = true;
      } else if (found) {
        return pane->pane_id;
      }

      previous = pane->pane_id;
    }

    return 0;
  }

  [[nodiscard]] std::uint16_t minimumExtent(std::size_t root, ClientLayoutAxis axis, Metrics metrics) const noexcept {
    std::array<std::uint16_t, maximum_panes> pending{};
    std::size_t count = 0;
    for (auto index = subtreeEnd(root); index-- > root;) {
      if (const auto *split = std::get_if<ClientLayoutSplit>(&nodes_[index])) {
        const auto first = pending[--count];
        const auto second = pending[--count];
        pending[count++] = split->axis == axis ? static_cast<std::uint16_t>(first + metrics.gap + second) : std::max(first, second);
      } else {
        pending[count++] = metrics.minimumPaneExtent(axis);
      }
    }

    return pending.front();
  }

  [[nodiscard]] std::optional<std::size_t> indexOf(std::uint64_t pane_id) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (const auto *pane = std::get_if<ClientLayoutPane>(&nodes_[index]); pane != nullptr && pane->pane_id == pane_id) {
        return index;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] std::size_t subtreeEnd(std::size_t beginning) const noexcept {
    std::size_t pending = 1;
    while (pending != 0 && beginning < count_) {
      if (std::holds_alternative<ClientLayoutSplit>(nodes_[beginning++])) {
        ++pending;
      } else {
        --pending;
      }
    }

    return beginning;
  }

  struct SplitGeometry {
    CellRectangle first;
    CellRectangle second;
    CellRectangle divider;
  };

  static SplitGeometry partition(CellRectangle bounds, const ClientLayoutSplit &split, std::uint16_t gap) noexcept {
    const bool horizontal = split.axis == ClientLayoutAxis::horizontal;
    const auto extent = horizontal ? bounds.width : bounds.height;
    constexpr std::uint16_t minimum_horizontal_split = 2;
    constexpr std::uint16_t minimum_vertical_split = 4;
    const auto minimum_split = horizontal ? minimum_horizontal_split : minimum_vertical_split;
    const auto separation = extent >= gap + minimum_split ? gap : 0;
    const auto first_extent = static_cast<std::uint16_t>(static_cast<std::uint32_t>(extent - separation) * split.ratio / ratio_maximum);
    auto first = bounds;
    auto second = bounds;
    auto divider = bounds;

    if (horizontal) {
      first.width = first_extent;
      second.x = static_cast<std::uint16_t>(second.x + first_extent + separation);
      second.width = static_cast<std::uint16_t>(second.width - first_extent - separation);
      divider.x = static_cast<std::uint16_t>(divider.x + first_extent);
      divider.width = static_cast<std::uint16_t>(separation);
    } else {
      first.height = first_extent;
      second.y = static_cast<std::uint16_t>(second.y + first_extent + separation);
      second.height = static_cast<std::uint16_t>(second.height - first_extent - separation);
      divider.y = static_cast<std::uint16_t>(divider.y + first_extent);
      divider.height = static_cast<std::uint16_t>(separation);
    }

    return {.first = first, .second = second, .divider = divider};
  }

  void arrangeNodes(CellRectangle bounds, Metrics metrics) noexcept {
    std::array<CellRectangle, maximum_panes> pending;
    std::size_t pending_count = 1;
    pending[0] = bounds;

    for (std::size_t index = 0; index < count_; ++index) {
      const auto current = pending[--pending_count];
      const auto &node = nodes_[index];
      if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
        placements_[placement_count_] = {.pane_id = pane->pane_id, .bounds = current, .display_index = static_cast<std::uint16_t>(placement_count_ + 1), .content = hasBorders(false, metrics) ? metrics.content(current) : current, .framed = hasBorders(false, metrics)};
        ++placement_count_;

        continue;
      }

      if (const auto *split = std::get_if<ClientLayoutSplit>(&node)) {
        const auto geometry = partition(current, *split, metrics.gap);
        dividers_[divider_count_++] = {.node_index = index, .axis = split->axis, .bounds = geometry.divider, .parent_bounds = current};
        pending[pending_count++] = geometry.second;
        pending[pending_count++] = geometry.first;
      }
    }
  }

  std::array<ClientLayoutNode, maximum_nodes> nodes_;
  std::array<Placement, maximum_panes> placements_;
  std::array<Divider, maximum_panes - 1> dividers_;
  std::optional<PaneBottomReservation> reservation_;
  CellRectangle reserved_;
  std::size_t count_ = 0;
  std::size_t placement_count_ = 0;
  std::size_t divider_count_ = 0;
};

}
