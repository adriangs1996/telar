#pragma once

#include "core/geometry.hpp"
#include "core/terminal_surface.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

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

  [[nodiscard]] static bool tracked(const Mouse &protocol, MousePhase phase) noexcept {
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

  [[nodiscard]] static std::optional<ChildMouseReport> project(const ChildMouseView &view, const ChildMouseSample &sample) noexcept {
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

  [[nodiscard]] static bool valid(const TerminalSurface &surface) noexcept {
    const auto finite_bounds = std::isfinite(surface.content.x) && std::isfinite(surface.content.y) && std::isfinite(surface.content.width) && std::isfinite(surface.content.height);
    const auto finite_metrics = std::isfinite(surface.cell.x) && std::isfinite(surface.cell.y) && std::isfinite(surface.scale);

    return finite_bounds && finite_metrics && !surface.content.empty() && surface.cell.x > 0 && surface.cell.y > 0 && surface.scale > 0;
  }

private:
  [[nodiscard]] static unsigned coordinate(double position, unsigned extent) noexcept {
    return static_cast<unsigned>(std::clamp(position, 0.0, static_cast<double>(extent - 1))) + 1;
  }
};

class ChildMouseGesture {
public:
  void begin(const ChildMouseView &view, ChildMouseSample sample) noexcept {
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

  [[nodiscard]] bool owned() const noexcept {
    return owned_;
  }

  [[nodiscard]] std::optional<ChildMouseReport> deliver(const ChildMouseView &view, ChildMouseSample sample) noexcept {
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

  [[nodiscard]] std::optional<ChildMouseReport> cancel(const ChildMouseView &view) noexcept {
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
