module;
#include <cstdio>

#include <cmath>
#include <cstdint>

#include <cstddef>

#include <cstring>



export module telar.gui.input.child_mouse;

import std;

export import telar.gui.core.metrics;


export import telar.gui.history.browser;
export import telar.gui.presentation.history_filter_geometry;


export import telar.gui.presentation.history_meta_geometry;


export import telar.gui.presentation.frame_pacer;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: input/child_mouse.cppm
export {
namespace telar::gui {

enum class MouseButton : std::uint8_t {
  left,
  middle,
  right,
  none,
};

enum class MousePhase : std::uint8_t {
  press,
  drag,
  release,
  move,
};

struct ChildMouseSample {
  MouseButton button = MouseButton::left;
  MousePhase phase = MousePhase::press;
  Point position;
  unsigned modifiers = 0;
};

struct ChildMouseView {
  std::uint64_t pane_id = 0;
  TabLocation location;
  TerminalSurface surface{};
  Mouse protocol{};
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  std::uint16_t cell_width_px = 0;
  std::uint16_t cell_height_px = 0;
  bool attached = false;
  bool visible = true;
};

struct ChildMouseReport {
  unsigned button = 0;
  unsigned x = 0;
  unsigned y = 0;
  bool released = false;

  bool operator==(const ChildMouseReport &) const = default;
};

class ChildMouseProjection {
public:
  static constexpr unsigned motion = 32;

  [[nodiscard]] inline static bool tracked(const Mouse &protocol, MousePhase phase) noexcept {
    if (!protocol.sgr) {
      return false;
    }

    switch (protocol.tracking) {
    case MouseTracking::none:
      return false;
    case MouseTracking::x10:
      return phase == MousePhase::press;
    case MouseTracking::normal:
      return phase == MousePhase::press || phase == MousePhase::release;
    case MouseTracking::button:
      return phase != MousePhase::move;
    case MouseTracking::any:
      return true;
    }

    return false;
  }

  [[nodiscard]] inline static std::optional<ChildMouseReport> project(const ChildMouseView &view, const ChildMouseSample &sample) noexcept {
    const auto &surface = view.surface;
    if (!view.attached || !tracked(view.protocol, sample.phase) || !valid(surface) || !std::isfinite(sample.position.x) || !std::isfinite(sample.position.y)) {
      return {};
    }

    const auto columns = std::min(static_cast<double>(view.columns), std::floor(static_cast<double>(surface.content.width) / surface.cell.x));
    const auto rows = std::min(static_cast<double>(view.rows), std::floor(static_cast<double>(surface.content.height) / surface.cell.y));
    if (columns < 1 || rows < 1 || (view.protocol.pixels && (view.cell_width_px == 0 || view.cell_height_px == 0))) {
      return {};
    }

    auto button = static_cast<unsigned>(sample.button) | sample.modifiers;
    if (sample.phase == MousePhase::drag || sample.phase == MousePhase::move) {
      button |= motion;
    }

    const auto scale_x = view.protocol.pixels ? surface.scale : 1 / static_cast<double>(surface.cell.x);
    const auto scale_y = view.protocol.pixels ? surface.scale : 1 / static_cast<double>(surface.cell.y);
    const auto width = static_cast<unsigned>(columns * (view.protocol.pixels ? view.cell_width_px : 1));
    const auto height = static_cast<unsigned>(rows * (view.protocol.pixels ? view.cell_height_px : 1));

    return ChildMouseReport{.button = button, .x = coordinate((sample.position.x - surface.content.x) * scale_x, width), .y = coordinate((sample.position.y - surface.content.y) * scale_y, height), .released = sample.phase == MousePhase::release};
  }

  [[nodiscard]] inline static bool valid(const TerminalSurface &surface) noexcept {
    const auto finite_bounds = std::isfinite(surface.content.x) && std::isfinite(surface.content.y) && std::isfinite(surface.content.width) && std::isfinite(surface.content.height);
    const auto finite_metrics = std::isfinite(surface.cell.x) && std::isfinite(surface.cell.y) && std::isfinite(surface.scale);

    return finite_bounds && finite_metrics && !surface.content.empty() && surface.cell.x > 0 && surface.cell.y > 0 && surface.scale > 0;
  }

private:
  [[nodiscard]] inline static unsigned coordinate(double position, unsigned extent) noexcept {
    return static_cast<unsigned>(std::clamp(position, 0.0, static_cast<double>(extent - 1))) + 1;
  }
};

class ChildMouseGesture {
public:
  inline void begin(const ChildMouseView &view, ChildMouseSample sample) noexcept {
    last_ = sample;
    owned_ = sample.phase == MousePhase::press && sample.button != MouseButton::none;
    capture_.reset();
    if (!owned_ || !view.attached || !view.visible || view.columns == 0 || view.rows == 0 || !ChildMouseProjection::valid(view.surface)) {
      return;
    }

    if (!view.protocol.sgr || view.protocol.tracking == MouseTracking::none || view.protocol.tracking == MouseTracking::x10 || view.cell_width_px == 0 || view.cell_height_px == 0) {
      return;
    }

    capture_ = view;
  }

  [[nodiscard]] inline bool owned() const noexcept {
    return owned_;
  }

  [[nodiscard]] inline std::optional<ChildMouseReport> deliver(const ChildMouseView &view, ChildMouseSample sample) noexcept {
    if (!owned_ || sample.button != last_.button || (sample.phase != MousePhase::drag && sample.phase != MousePhase::release)) {
      return {};
    }

    last_ = sample;
    if (sample.phase == MousePhase::release) {
      owned_ = false;
    }

    if (!capture_ || !view.attached || capture_->pane_id != view.pane_id || capture_->surface.attachment_generation != view.surface.attachment_generation || !sameTab(capture_->location, view.location)) {
      return {};
    }

    if (view.visible && ChildMouseProjection::valid(view.surface) && view.cell_width_px != 0 && view.cell_height_px != 0) {
      capture_->surface = view.surface;
      capture_->cell_width_px = view.cell_width_px;
      capture_->cell_height_px = view.cell_height_px;
    }

    auto projected = view;
    projected.surface = capture_->surface;
    projected.cell_width_px = capture_->cell_width_px;
    projected.cell_height_px = capture_->cell_height_px;

    return ChildMouseProjection::project(projected, sample);
  }

  [[nodiscard]] inline std::optional<ChildMouseReport> cancel(const ChildMouseView &view) noexcept {
    auto release = last_;
    release.phase = MousePhase::release;

    return deliver(view, release);
  }

private:
  bool owned_ = false;
  std::optional<ChildMouseView> capture_;
  ChildMouseSample last_;
};

}
}

// Interface: input/history_action_capture.cppm
export {
namespace telar::gui {

struct HistoryActionPosition {
  double x = 0;
  double y = 0;
};

struct HistoryActionTarget {
  HistoryCardAction action = HistoryCardAction::copy;
  Rect bounds{};
  bool enabled = false;

  [[nodiscard]] inline bool contains(HistoryActionPosition position) const noexcept {
    return position.x >= bounds.x && position.y >= bounds.y && position.x < static_cast<double>(bounds.x) + bounds.width && position.y < static_cast<double>(bounds.y) + bounds.height;
  }
};

struct HistoryActionSurface {
  std::array<HistoryActionTarget, HistoryActions::count> targets{};
  std::uint64_t generation = 0;
  double scale = 1;
  std::optional<HistoryChoice> choice = std::nullopt;

  [[nodiscard]] inline const HistoryActionTarget *find(HistoryCardAction action) const noexcept {
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
  [[nodiscard]] inline bool begin(const HistoryActionSurface &surface, HistoryActionPosition position, bool primary) noexcept {
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

  [[nodiscard]] inline bool held() const noexcept { return held_; }
  inline void cancel() noexcept { action_.reset(); }

  inline void present(const HistoryActionSurface &surface) noexcept {
    const auto *target = action_ ? surface.find(*action_) : nullptr;
    if (surface.generation != generation_ || surface.choice != choice_ || target == nullptr || !target->enabled) {
      cancel();
    }
  }

  [[nodiscard]] inline std::optional<HistoryCardAction> release(const HistoryActionSurface &surface, HistoryActionPosition position) noexcept {
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
}

// Interface: input/history_hover.cppm
export {
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

  [[nodiscard]] inline bool submission() const noexcept {
    return action == HistoryFooterAction::submit || action == HistoryFooterAction::alternate;
  }

  bool operator==(const HistoryFooterIdentity &other) const noexcept {
    return action == other.action && (!submission() || choice == other.choice);
  }
};

struct HistoryInspectionIdentity {
  HistoryInspectionAction action = HistoryInspectionAction::submit;
  HistoryChoice choice;

  [[nodiscard]] inline bool submission() const noexcept {
    return action == HistoryInspectionAction::submit || action == HistoryInspectionAction::alternate;
  }

  bool operator==(const HistoryInspectionIdentity &other) const noexcept {
    return action == other.action && (!submission() || choice == other.choice);
  }
};

struct HistoryHoverIdentity {
  std::variant<HistoryChoice, HistoryCardAction, HistoryFooterIdentity, HistoryFilterAction, HistoryInspectionIdentity> action;
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

    if (filter != nullptr) {
      return other_filter != nullptr && *filter == *other_filter;
    }

    const auto *inspection = std::get_if<HistoryInspectionIdentity>(&action);
    const auto *other_inspection = std::get_if<HistoryInspectionIdentity>(&other.action);

    return inspection != nullptr && other_inspection != nullptr && *inspection == *other_inspection;
  }
};

struct HistoryHoverTarget {
  HistoryHoverIdentity identity;
  Rect bounds{};

  [[nodiscard]] inline bool contains(HistoryActionPosition position) const noexcept {
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

  [[nodiscard]] inline const std::optional<HistoryHoverIdentity> &hovered() const noexcept { return hovered_; }

  inline bool cancel() noexcept {
    const bool changed = hovered_.has_value();
    hovered_.reset();

    return changed;
  }

  inline bool present(std::span<const HistoryHoverTarget> targets) noexcept {
    if (hovered_ && std::ranges::none_of(targets, [&](const HistoryHoverTarget &target) { return target.identity == *hovered_ && !target.bounds.empty(); })) {
      return cancel();
    }

    return false;
  }

  inline bool observe(std::span<const HistoryHoverTarget> targets, HistoryActionPosition position, Observation observation) noexcept {
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
}

// Interface: input/history_scroll.cppm
export {
namespace telar::gui {

struct HistoryScrollState {
  std::uint64_t generation = 0;
  std::uint64_t revision = 0;
  bool ready = false;
  bool inspecting = false;
};

struct HistoryScrollSurface {
  Rect bounds{};
  std::uint64_t generation = 0;
  std::uint64_t revision = 0;
  double row_height = 1;
  double cell_height = 1;
  double scale = 1;
  bool delivered = false;
  bool has_rows = false;
};

struct HistoryScrollPosition {
  double x = 0;
  double y = 0;
};

class HistoryScroll {
public:
  [[nodiscard]] inline std::int32_t consume(HistoryScrollState state, const HistoryScrollSurface &surface, HistoryScrollPosition pointer, ScrollSample sample) noexcept {
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

private:
  [[nodiscard]] inline static bool within(Rect bounds, HistoryScrollPosition pointer) noexcept {
    return pointer.x >= bounds.x && pointer.y >= bounds.y && pointer.x < static_cast<double>(bounds.x) + bounds.width && pointer.y < static_cast<double>(bounds.y) + bounds.height;
  }

  WheelAccumulator wheel_;
  std::uint64_t generation_ = 0;
  bool inspecting_ = false;
};

}
}

// Interface: input/tab_drag.cppm
export {
namespace telar::gui {

struct TabDropTarget {
  std::optional<std::uint64_t> relative_to;
  TabMoveDirection direction = TabMoveDirection::previous;
};

struct TabDragMove {
  TabLocation location;
  TabMoveDirection direction = TabMoveDirection::previous;
  std::optional<std::uint64_t> relative_to;
};

class TabDrag {
public:
  using Position = std::array<double, 2>;
  static constexpr double logical_threshold = 4;

  inline void begin(TabLocation source, Position point) noexcept {
    *this = {};
    captured_ = true;
    source_ = source;
    origin_ = point;
  }

  inline void cancel() noexcept {
    source_.reset();
    destination_.reset();
    dragging_ = false;
  }

  inline void validate(std::optional<WorkspaceLocation> workspace, std::span<const std::uint64_t> tabs, bool naming) noexcept {
    if (source_ && (naming || !workspace || workspace->kind != source_->workspace.kind || workspace->id != source_->workspace.id || std::ranges::find(tabs, source_->tab_id) == tabs.end())) {
      cancel();
    }
  }

  inline void update(Position point, std::optional<TabDropTarget> destination) noexcept {
    if (!source_) {
      return;
    }

    constexpr double threshold = 1;
    dragging_ = dragging_ || std::abs(point[0] - origin_[0]) >= threshold || std::abs(point[1] - origin_[1]) >= threshold;
    destination_ = dragging_ && destination && destination->relative_to != source_->tab_id ? destination : std::nullopt;
  }

  [[nodiscard]] inline std::optional<TabDragMove> preview() const noexcept {
    if (!source_ || !destination_) {
      return std::nullopt;
    }

    return TabDragMove{.location = *source_, .direction = destination_->direction, .relative_to = destination_->relative_to};
  }

  [[nodiscard]] inline std::optional<TabDragMove> finish() noexcept {
    const auto result = preview();
    *this = {};

    return result;
  }

  [[nodiscard]] inline bool captured() const noexcept {
    return captured_;
  }

  [[nodiscard]] inline bool dragging() const noexcept {
    return dragging_;
  }

  [[nodiscard]] inline const std::optional<TabLocation> &source() const noexcept {
    return source_;
  }

  [[nodiscard]] inline const std::optional<TabDropTarget> &destination() const noexcept {
    return destination_;
  }

private:
  bool captured_ = false;
  std::optional<TabLocation> source_;
  Position origin_{};
  bool dragging_ = false;
  std::optional<TabDropTarget> destination_;
};

}
}

// Interface: input/tab_drop_slots.cppm
export {
namespace telar::gui {

struct TabDropSlot {
  std::uint64_t id = 0;
  Rect bounds;
};

class TabDropSlots {
public:
  static constexpr std::size_t capacity = TabStripGeometry::maximum_tabs;

  inline void capture(std::span<const TabDropSlot> delivered) noexcept {
    count_ = std::min(delivered.size(), entries_.size());
    std::copy_n(delivered.begin(), count_, entries_.begin());
  }

  [[nodiscard]] inline std::optional<TabDropTarget> at(TabDrag::Position point) const noexcept {
    const TabDropSlot *nearest = nullptr;
    double distance = std::numeric_limits<double>::infinity();
    double left = std::numeric_limits<double>::infinity();
    double right = -std::numeric_limits<double>::infinity();
    for (const auto &slot : std::span{entries_}.first(count_)) {
      if (point[1] < slot.bounds.y || point[1] >= slot.bounds.y + slot.bounds.height) {
        continue;
      }

      left = std::min(left, static_cast<double>(slot.bounds.x));
      right = std::max(right, static_cast<double>(slot.bounds.x + slot.bounds.width));
      const auto horizontal_distance = std::max({0.0, slot.bounds.x - point[0], point[0] - (slot.bounds.x + slot.bounds.width)});
      if (horizontal_distance < distance) {
        nearest = &slot;
        distance = horizontal_distance;
      }
    }

    if (point[0] < left || point[0] >= right || nearest == nullptr) {
      return std::nullopt;
    }

    return TabDropTarget{.relative_to = nearest->id, .direction = point[0] < nearest->bounds.x + (nearest->bounds.width / 2) ? TabMoveDirection::previous : TabMoveDirection::next};
  }

  [[nodiscard]] inline std::span<const TabDropSlot> view() const noexcept {
    return std::span{entries_}.first(count_);
  }

private:
  std::array<TabDropSlot, capacity> entries_{};
  std::size_t count_ = 0;
};

}
}

// Interface: input/tab_drop_surface.cppm
export {
namespace telar::gui {

struct TabDropSurface {
  std::array<TabDropSlot, TabDropSlots::capacity> targets{};
  std::size_t count = 0;
  WorkspaceLocation workspace;
  Rect viewport;
  Rect create;
  std::uint64_t machine_view = 0;
  double scale = 1;
  double threshold = TabDrag::logical_threshold;

  [[nodiscard]] inline const TabDropSlot *at(TabDrag::Position point) const noexcept {
    const auto contains = [&](const Rect &bounds) {
      return point[0] >= bounds.x && point[0] < bounds.right() && point[1] >= bounds.y && point[1] < bounds.bottom();
    };
    if (contains(create)) {
      return nullptr;
    }
    for (const auto &target : std::span{targets}.first(count) | std::views::reverse) {
      if (contains(target.bounds)) {
        return &target;
      }
    }
    return nullptr;
  }

  [[nodiscard]] inline std::span<const TabDropSlot> view() const noexcept {
    return std::span{targets}.first(count);
  }
};

}
}
