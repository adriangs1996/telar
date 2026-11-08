module;
#include <cmath>
#include <cstdint>

export module telar.gui.tools.probe_geometry;

import std;
export import telar.gui.tools.probe_io;
export import telar.gui.core.metrics;

export {
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
}
