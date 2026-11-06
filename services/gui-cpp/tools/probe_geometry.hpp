#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "probe_io.hpp"

#pragma once


import telar.gui.core.metrics;

namespace telar::gui::probe {

inline Rect readRect() {
  const auto x = read<float>();
  const auto y = read<float>();
  const auto width = read<float>();
  const auto height = read<float>();

  return {.x = x, .y = y, .width = width, .height = height};
}

inline void writeRect(Rect bounds) {
  write(bounds.x);
  write(bounds.y);
  write(bounds.width);
  write(bounds.height);
}

}
