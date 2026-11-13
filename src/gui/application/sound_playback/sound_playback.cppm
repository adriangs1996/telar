module;
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstdint>

#include <cstddef>




#include <cmath>
#include "tbc/view.hpp"

export module telar.gui.application.sound_playback;

import std;

export import telar.gui.core.unicode_scalar;


export import telar.base.text;


export import telar.gui.core.metrics;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: application/pane_bottom_reservation.cppm
export {
namespace telar::gui {

struct PaneBottomReservation {
  static constexpr std::uint16_t shelf_rows = 6;
  static constexpr std::uint16_t shelf_minimum_rows = 3;
  static constexpr std::uint16_t pane_minimum_rows = 3;

  std::uint64_t pane_id = 0;
  std::uint16_t preferred_height = shelf_rows;
  std::uint16_t minimum_height = shelf_minimum_rows;
  std::uint16_t minimum_pane_height = pane_minimum_rows;

  bool operator==(const PaneBottomReservation &) const = default;
};

}
}

// Interface: application/pane_layout.cppm
export {
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

    [[nodiscard]] inline std::uint16_t minimumPaneExtent(ClientLayoutAxis axis = ClientLayoutAxis::horizontal) const noexcept {
      return border == 0 ? 1 : 1 + static_cast<std::uint16_t>(border) + (axis == ClientLayoutAxis::vertical ? std::max(border, header) : border);
    }

    [[nodiscard]] inline CellRectangle content(CellRectangle bounds) const noexcept {
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

  [[nodiscard]] inline static bool hasBorders(Metrics metrics) noexcept {
    return metrics.border != 0;
  }

  inline void restore(std::span<const ClientLayoutNode> nodes) {
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

  inline bool add(std::uint64_t pane_id, ClientLayoutAxis axis, std::uint64_t beside) noexcept {
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

  inline bool remove(std::uint64_t pane_id) noexcept {
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

  inline void setBottomReservation(std::optional<PaneBottomReservation> reservation) noexcept {
    reservation_ = reservation;
  }

  [[nodiscard]] inline CellRectangle reservedArea() const noexcept {
    return reserved_;
  }

  inline std::span<const Placement> arrange(CellRectangle bounds, Metrics metrics, std::optional<std::uint64_t> fullscreen = {}) noexcept {
    placement_count_ = 0;
    divider_count_ = 0;
    reserved_ = {};
    if (fullscreen && contains(*fullscreen)) {
      placements_[placement_count_++] = {.pane_id = *fullscreen, .bounds = bounds, .display_index = displayIndex(*fullscreen), .content = bounds.inner(metrics.border), .framed = hasBorders(metrics)};
    } else if (count_ != 0) {
      arrangeNodes(bounds, metrics);
    }

    reserveBelowPane(metrics);

    return {placements_.data(), placement_count_};
  }

  [[nodiscard]] inline std::span<const Divider> dividers() const noexcept {
    return {dividers_.data(), divider_count_};
  }

  [[nodiscard]] inline std::optional<SplitBounds> prospectiveSplit(CellRectangle area, ClientLayoutAxis axis, std::uint64_t pane_id, Metrics metrics, std::optional<std::uint64_t> fullscreen = {}) noexcept {
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

  inline bool setSplitRatio(DividerPosition position) noexcept {
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

  [[nodiscard]] inline std::uint64_t focusTarget(CellRectangle area, Metrics metrics, FocusRequest request) noexcept {
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

  inline bool resize(std::uint64_t pane_id, PaneDirection direction, CellRectangle area, Metrics metrics) noexcept {
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

  [[nodiscard]] inline bool contains(std::uint64_t pane_id) const noexcept {
    return indexOf(pane_id).has_value();
  }

  [[nodiscard]] inline std::span<const ClientLayoutNode> nodes() const noexcept {
    return {nodes_.data(), count_};
  }

  [[nodiscard]] inline std::uint64_t firstPane() const noexcept {
    for (const auto &node : nodes()) {
      if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
        return pane->pane_id;
      }
    }

    return 0;
  }

  [[nodiscard]] inline std::uint16_t displayIndex(std::uint64_t pane_id) const noexcept {
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
  inline void reserveBelowPane(Metrics metrics) noexcept {
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

    [[nodiscard]] inline std::optional<std::uint64_t> score(CellRectangle candidate) const noexcept {
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

  inline bool moveDivider(std::size_t index, bool decreasing, CellRectangle area, Metrics metrics) noexcept {
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

  [[nodiscard]] inline std::uint64_t fullscreenFocusTarget(FocusRequest request) const noexcept {
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

  [[nodiscard]] inline std::uint16_t minimumExtent(std::size_t root, ClientLayoutAxis axis, Metrics metrics) const noexcept {
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

  [[nodiscard]] inline std::optional<std::size_t> indexOf(std::uint64_t pane_id) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (const auto *pane = std::get_if<ClientLayoutPane>(&nodes_[index]); pane != nullptr && pane->pane_id == pane_id) {
        return index;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] inline std::size_t subtreeEnd(std::size_t beginning) const noexcept {
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

  inline static SplitGeometry partition(CellRectangle bounds, const ClientLayoutSplit &split, std::uint16_t gap) noexcept {
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

  inline void arrangeNodes(CellRectangle bounds, Metrics metrics) noexcept {
    std::array<CellRectangle, maximum_panes> pending;
    std::size_t pending_count = 1;
    pending[0] = bounds;

    for (std::size_t index = 0; index < count_; ++index) {
      const auto current = pending[--pending_count];
      const auto &node = nodes_[index];
      if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
        placements_[placement_count_] = {.pane_id = pane->pane_id, .bounds = current, .display_index = static_cast<std::uint16_t>(placement_count_ + 1), .content = hasBorders(metrics) ? metrics.content(current) : current, .framed = hasBorders(metrics)};
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
}

// Interface: application/layout_token.cppm
export {
namespace telar::gui {

struct TabLayoutPreset {
  TabLocation location;
  PaneLayout layout;
  std::uint64_t focused_pane = 0;
  bool fullscreen = false;
};

class LayoutToken {
public:
  static constexpr std::size_t text_capacity = 4096;
  static constexpr std::size_t digits_per_byte = 2;
  static constexpr std::size_t binary_capacity = text_capacity / digits_per_byte;

  template <Allocator Memory>
  // The token is written into the output, region `a`.
  inline static tbc::view<std::string_view, tbc::lt::a> write(const ClientLayoutSnapshot &snapshot, tbc::view<String<Memory> &, tbc::lt::a> output) {
    std::array<Byte, binary_capacity> binary{};
    const auto encoded = Codec::encode(snapshot, binary);
    output.clear();
    output.reserve(encoded.size() * digits_per_byte);
    runtime::appendLowerHex(output, encoded);

    return output;
  }

  inline static TabLayoutPreset read(std::string_view text) {
    std::array<Byte, binary_capacity> binary{};
    const auto bytes = decodeHexadecimal(text, binary);
    constexpr auto storage_capacity = (PaneLayout::maximum_nodes * sizeof(ClientLayoutNode)) + sizeof(ClientTabLayout) + alignof(ClientLayoutNode) + alignof(ClientTabLayout);
    std::array<Byte, storage_capacity> elements{};
    DecodeStorage storage{elements};
    const auto snapshot = Codec::decode<ClientLayoutSnapshot>(bytes, storage);
    if (!snapshot.restored || !snapshot.active_tab || snapshot.tabs.size() != 1) {
      throw EncodingError{"Layout token must describe one restored tab"};
    }

    const auto &tab = snapshot.tabs.front();
    if (!sameTab(tab.location, *snapshot.active_tab)) {
      throw EncodingError{"Layout token tab does not match its active tab"};
    }

    TabLayoutPreset preset;
    preset.location = tab.location;
    preset.focused_pane = tab.focused_pane;
    preset.fullscreen = tab.fullscreen;
    preset.layout.restore(tab.nodes);

    return preset;
  }

private:
  inline static tbc::view<std::span<const Byte>, tbc::lt::a> decodeHexadecimal(std::string_view text, tbc::view<std::span<Byte>, tbc::lt::a> output) {
    // Hexadecimal decoding error names, checked in this order.
    if (text.empty() || text.size() % digits_per_byte != 0) {
      throw EncodingError{"InvalidLength"};
    }

    if (text.size() > text_capacity) {
      throw EncodingError{"NoSpaceLeft"};
    }

    constexpr int hexadecimal_base = 16;
    const auto size = text.size() / digits_per_byte;
    for (std::size_t index = 0; index < size; ++index) {
      const auto digits = text.substr(index * digits_per_byte, digits_per_byte);
      unsigned value = 0;
      const auto parsed = std::from_chars(digits.data(), digits.data() + digits.size(), value, hexadecimal_base);
      if (parsed.ec != std::errc{} || parsed.ptr != digits.data() + digits.size()) {
        throw EncodingError{"InvalidCharacter"};
      }

      output[index] = static_cast<Byte>(value);
    }

    return output.first(size);
  }
};

}
}

// Interface: application/navigation_history.cppm
export {
namespace telar::gui {

class NavigationHistory {
public:
  static constexpr std::size_t capacity = 64;

  struct Layout {
    inline explicit Layout(const PaneLayout &layout, std::uint64_t focus) noexcept
        : count(layout.nodes().size()),
          focused_pane(focus) {
      std::ranges::copy(layout.nodes(), nodes.begin());
    }

    inline explicit Layout(std::span<const ClientLayoutNode> input, std::uint64_t focus = 0)
        : count(input.size()),
          focused_pane(focus) {
      if (input.size() > nodes.size()) {
        throw std::length_error{"Navigation layout exceeds capacity"};
      }

      std::ranges::copy(input, nodes.begin());
    }

    [[nodiscard]] inline std::span<const ClientLayoutNode> view() const noexcept {
      return std::span{nodes}.first(count);
    }

    std::array<ClientLayoutNode, PaneLayout::maximum_nodes> nodes{};
    std::size_t count = 0;
    std::uint64_t focused_pane = 0;
  };

  struct Bookmark {
    TabLocation location{};
    std::uint64_t pane_id = 0;
    std::optional<Layout> layout = std::nullopt;
    bool fullscreen = false;
  };

  inline void clear() noexcept {
    for (auto &entry : entries_) {
      entry.reset();
    }
  }

  inline void remember(const Bookmark &bookmark) noexcept {
    std::optional<Bookmark> *free = nullptr;
    for (auto &entry : entries_) {
      if (entry) {
        if (sameWorkspace(entry->location.workspace, bookmark.location.workspace)) {
          entry = bookmark;

          return;
        }
      } else if (free == nullptr) {
        free = std::addressof(entry);
      }
    }

    if (free != nullptr) {
      *free = bookmark;
    }
  }

  [[nodiscard]] inline const Bookmark *find(WorkspaceLocation workspace) const noexcept {
    for (const auto &entry : entries_) {
      if (entry && sameWorkspace(entry->location.workspace, workspace)) {
        return std::addressof(*entry);
      }
    }

    return nullptr;
  }

  inline void forget(WorkspaceLocation workspace) noexcept {
    for (auto &entry : entries_) {
      if (entry && sameWorkspace(entry->location.workspace, workspace)) {
        entry.reset();

        return;
      }
    }
  }

private:
  std::array<std::optional<Bookmark>, capacity> entries_{};
};

}
}

// Interface: application/saved_layouts.cppm
export {
namespace telar::gui {

class SavedLayouts {
public:
  static constexpr std::size_t capacity = 256;
  static constexpr std::size_t node_capacity = (capacity * 2) - 1;

  struct View {
    TabLocation location{};
    std::uint64_t pane_id = 0;
    std::uint64_t focused_pane = 0;
    bool workspace_active = false;
    bool fullscreen = false;
    std::span<const ClientLayoutNode> nodes;
  };

  [[nodiscard]] inline std::size_t size() const noexcept {
    return count_;
  }

  [[nodiscard]] inline std::size_t nodeCount() const noexcept {
    return node_total_;
  }

  inline void clear() noexcept {
    count_ = 0;
    node_total_ = 0;
  }

  [[nodiscard]] inline View at(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"Saved layout row exceeds capacity"};
    }

    const auto &row = rows_[index];

    return {.location = row.location, .pane_id = row.pane_id, .focused_pane = row.focused_pane, .workspace_active = row.workspace_active, .fullscreen = row.fullscreen, .nodes = std::span{nodes_}.subspan(row.start, row.count)};
  }

  [[nodiscard]] inline std::optional<View> find(TabLocation location) const {
    const auto index = row(location);

    return index && rows_[*index].count != 0 ? std::optional{at(*index)} : std::nullopt;
  }

  inline bool remember(View saved) noexcept {
    const auto existing = row(saved.location);
    const auto freed_rows = existing ? std::size_t{1} : 0;
    const auto freed_nodes = existing ? rows_[*existing].count : 0;
    if (count_ - freed_rows == capacity || saved.nodes.size() > nodes_.size() - node_total_ + freed_nodes || saved.nodes.size() > PaneLayout::maximum_nodes) {
      return false;
    }

    std::array<ClientLayoutNode, PaneLayout::maximum_nodes> captured{};
    std::ranges::copy(saved.nodes, captured.begin());
    if (existing) {
      remove(*existing);
    }

    rows_[count_] = {.location = saved.location, .pane_id = saved.pane_id, .focused_pane = saved.focused_pane, .workspace_active = saved.workspace_active, .fullscreen = saved.fullscreen, .start = node_total_, .count = saved.nodes.size()};
    std::copy_n(captured.begin(), saved.nodes.size(), nodes_.begin() + node_total_);
    node_total_ += saved.nodes.size();
    ++count_;

    return true;
  }

  inline void retain(View saved) noexcept {
    if (saved.nodes.size() > PaneLayout::maximum_nodes) {
      return;
    }

    std::array<ClientLayoutNode, PaneLayout::maximum_nodes> captured{};
    std::ranges::copy(saved.nodes, captured.begin());
    saved.nodes = std::span{captured}.first(saved.nodes.size());
    while (!remember(saved)) {
      if (count_ == 0) {
        return;
      }

      remove(0);
    }
  }

  inline void forget(TabLocation location) noexcept {
    if (const auto index = row(location)) {
      remove(*index);
    }
  }

private:
  struct Row {
    TabLocation location{};
    std::uint64_t pane_id = 0;
    std::uint64_t focused_pane = 0;
    bool workspace_active = false;
    bool fullscreen = false;
    std::size_t start = 0;
    std::size_t count = 0;
  };

  [[nodiscard]] inline std::optional<std::size_t> row(TabLocation location) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      if (sameTab(rows_[index].location, location)) {
        return index;
      }
    }

    return std::nullopt;
  }

  inline void remove(std::size_t index) noexcept {
    const auto start = rows_[index].start;
    const auto count = rows_[index].count;
    std::move(nodes_.begin() + start + count, nodes_.begin() + node_total_, nodes_.begin() + start);
    node_total_ -= count;
    std::move(rows_.begin() + index + 1, rows_.begin() + count_, rows_.begin() + index);
    --count_;
    for (auto &moved : std::span{rows_}.subspan(index, count_ - index)) {
      moved.start -= count;
    }
  }

  std::array<Row, capacity> rows_{};
  std::array<ClientLayoutNode, node_capacity> nodes_{};
  std::size_t count_ = 0;
  std::size_t node_total_ = 0;
};

}
}

// Interface: application/sound_playback.cppm
export {
namespace telar::gui {

struct SoundRequestOutcome {
  enum class State : std::uint8_t {
    ignored,
    queued,
    start,
  };

  State state = State::ignored;
  AgentSound sound = AgentSound::ready;
};

class SoundPlayback {
public:
  inline explicit SoundPlayback(SoundPolicy configuration = {}) noexcept
      : configuration_(configuration) {}

  [[nodiscard]] inline SoundPolicy configuration() const noexcept {
    return configuration_;
  }

  [[nodiscard]] inline bool active() const noexcept {
    return active_;
  }

  [[nodiscard]] inline std::optional<AgentSound> queued() const noexcept {
    return queued_;
  }

  [[nodiscard]] inline SoundRequestOutcome request(AgentSound kind) noexcept {
    if (!allows(kind)) {
      return {};
    }

    if (active_) {
      queued_ = queued_ == AgentSound::needs_input || kind == AgentSound::needs_input ? AgentSound::needs_input : AgentSound::ready;

      return {.state = SoundRequestOutcome::State::queued};
    }

    active_ = true;

    return {.state = SoundRequestOutcome::State::start, .sound = kind};
  }

  [[nodiscard]] inline std::optional<AgentSound> complete() {
    if (!active_) {
      throw std::logic_error{"NoActiveSoundPlayback"};
    }

    active_ = false;
    const auto next = std::exchange(queued_, std::nullopt);
    if (!next || !allows(*next)) {
      return std::nullopt;
    }

    active_ = true;

    return next;
  }

  inline void schedulingFailed() {
    if (!active_ || queued_) {
      throw std::logic_error{"InvalidSoundSchedulingFailure"};
    }

    active_ = false;
  }

  inline void configure(SoundPolicy configuration) noexcept {
    configuration_ = configuration;
    if (queued_ && !allows(*queued_)) {
      queued_.reset();
    }
  }

private:
  [[nodiscard]] inline bool allows(AgentSound kind) const noexcept {
    if (!configuration_.enabled) {
      return false;
    }

    switch (kind) {
    case AgentSound::ready:
      return configuration_.ready;
    case AgentSound::needs_input:
      return configuration_.needs_input;
    }

    return false;
  }

  SoundPolicy configuration_;
  std::optional<AgentSound> queued_;
  bool active_ = false;
};

}
}

// Interface: application/workbench_geometry.cppm
export {
namespace telar::gui {

struct WorkbenchGeometry {
  static constexpr float default_width = default_terminal_size.cols * default_terminal_size.cell_width_px;
  static constexpr float default_height = default_terminal_size.rows * default_terminal_size.cell_height_px;

  Rect area{.width = default_width, .height = default_height};
  TerminalGrid grid;
  PaneLayout::Metrics layout_metrics;

  bool operator==(const WorkbenchGeometry &) const = default;

  // A new pane opens alone in its tab, framed like any other pane.
  [[nodiscard]] inline std::optional<TerminalSize> launchSize() const noexcept {
    return contentSize(layout_metrics.content(cellArea()));
  }

  [[nodiscard]] inline CellRectangle cellArea() const noexcept {
    const auto size = grid.fit(area.width, area.height);

    return size ? CellRectangle{.width = size->cols, .height = size->rows} : CellRectangle{};
  }

  [[nodiscard]] inline std::optional<TerminalSize> contentSize(CellRectangle content) const noexcept {
    if (content.empty() || static_cast<std::size_t>(content.width) * content.height > TerminalGrid::maximum_cells) {
      return std::nullopt;
    }

    return TerminalSize{.cols = content.width, .rows = content.height, .cell_width_px = grid.cell_width_px, .cell_height_px = grid.cell_height_px};
  }

  [[nodiscard]] inline Rect pixels(CellRectangle cells) const noexcept {
    return {
        .x = area.x + static_cast<float>(static_cast<std::uint32_t>(cells.x) * grid.cell_width_px / grid.scale),
        .y = area.y + static_cast<float>(static_cast<std::uint32_t>(cells.y) * grid.cell_height_px / grid.scale),
        .width = static_cast<float>(static_cast<std::uint32_t>(cells.width) * grid.cell_width_px / grid.scale),
        .height = static_cast<float>(static_cast<std::uint32_t>(cells.height) * grid.cell_height_px / grid.scale),
    };
  }
};

}
}
