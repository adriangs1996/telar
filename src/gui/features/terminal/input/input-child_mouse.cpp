module telar.gui.features.terminal.input;

import std;

import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::input {

  bool ChildMouseProjection::tracked(const Mouse& protocol, MousePhase phase) noexcept {
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

  ds::Option<ChildMouseReport> ChildMouseProjection::project(const ChildMouseView& view, const ChildMouseSample& sample) noexcept {
    const auto& surface = view.surface;
    if (!view.attached || !tracked(view.protocol, sample.phase) || !valid(surface) || !std::isfinite(sample.position.x) || !std::isfinite(sample.position.y)) {
      return {};
    }

    const auto columns = std::min(static_cast<double>(view.columns), std::floor(static_cast<double>(surface.content.width) / static_cast<double>(surface.cell.x)));
    const auto rows = std::min(static_cast<double>(view.rows), std::floor(static_cast<double>(surface.content.height) / static_cast<double>(surface.cell.y)));
    if (columns < 1 || rows < 1 || (view.protocol.pixels && (view.cell_width_px == 0 || view.cell_height_px == 0))) {
      return {};
    }

    auto button = static_cast<unsigned>(sample.button) | sample.modifiers;

    if (sample.phase == MousePhase::drag || sample.phase == MousePhase::move) {
      button |= motion;
    }

    const auto scale_x = view.protocol.pixels ? static_cast<double>(surface.scale) : 1 / static_cast<double>(surface.cell.x);
    const auto scale_y = view.protocol.pixels ? static_cast<double>(surface.scale) : 1 / static_cast<double>(surface.cell.y);
    const auto width = static_cast<unsigned>(columns * (view.protocol.pixels ? view.cell_width_px : 1));
    const auto height = static_cast<unsigned>(rows * (view.protocol.pixels ? view.cell_height_px : 1));

    return ChildMouseReport{.button = button, .x = coordinate(static_cast<double>(sample.position.x - surface.content.x) * scale_x, width), .y = coordinate(static_cast<double>(sample.position.y - surface.content.y) * scale_y, height), .released = sample.phase == MousePhase::release};
  }

  bool ChildMouseProjection::valid(const TerminalSurface& surface) noexcept {
    const auto finite_bounds = std::isfinite(surface.content.x) && std::isfinite(surface.content.y) && std::isfinite(surface.content.width) && std::isfinite(surface.content.height);
    const auto finite_metrics = std::isfinite(surface.cell.x) && std::isfinite(surface.cell.y) && std::isfinite(surface.scale);

    return finite_bounds && finite_metrics && !surface.content.empty() && surface.cell.x > 0 && surface.cell.y > 0 && surface.scale > 0;
  }

  unsigned ChildMouseProjection::coordinate(double position, unsigned extent) noexcept {
    return static_cast<unsigned>(std::clamp(position, 0.0, static_cast<double>(extent - 1))) + 1;
  }

  void ChildMouseGesture::begin(const ChildMouseView& view, ChildMouseSample sample) noexcept {
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

  bool ChildMouseGesture::owned() const noexcept {
    return owned_;
  }

  ds::Option<ChildMouseReport> ChildMouseGesture::deliver(const ChildMouseView& view, ChildMouseSample sample) noexcept {
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
      capture_.getMut().surface = view.surface;
      capture_.getMut().cell_width_px = view.cell_width_px;
      capture_.getMut().cell_height_px = view.cell_height_px;
    }

    auto projected = view;

    projected.surface = capture_->surface;
    projected.cell_width_px = capture_->cell_width_px;
    projected.cell_height_px = capture_->cell_height_px;

    return ChildMouseProjection::project(projected, sample);
  }

  ds::Option<ChildMouseReport> ChildMouseGesture::cancel(const ChildMouseView& view) noexcept {
    auto release = last_;

    release.phase = MousePhase::release;

    return deliver(view, release);
  }

}
