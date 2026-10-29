#pragma once

#include "geometry.hpp"
#include <cstdint>

namespace telar::gui {

struct TerminalSurface {
  Rect content;
  Point cell;
  std::uint64_t attachment_generation = 0;
  float scale = 1;

  bool operator==(const TerminalSurface &) const = default;
};

}
