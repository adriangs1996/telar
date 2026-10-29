#pragma once

#include "core/geometry.hpp"
#include "input/wheel_accumulator.hpp"
#include <cstdint>

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
  [[nodiscard]] std::int32_t consume(HistoryScrollState state, const HistoryScrollSurface &surface, HistoryScrollPosition pointer, ScrollSample sample) noexcept {
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
  [[nodiscard]] static bool within(Rect bounds, HistoryScrollPosition pointer) noexcept {
    return pointer.x >= bounds.x && pointer.y >= bounds.y && pointer.x < static_cast<double>(bounds.x) + bounds.width && pointer.y < static_cast<double>(bounds.y) + bounds.height;
  }

  WheelAccumulator wheel_;
  std::uint64_t generation_ = 0;
  bool inspecting_ = false;
};

}
