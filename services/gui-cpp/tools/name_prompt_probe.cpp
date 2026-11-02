#include "core/cell_rectangle.hpp"
#include "presentation/name_prompt_geometry.hpp"
#include "probe_io.hpp"
#include <array>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;

void writeRectangle(CellRectangle area) {
  const auto visible = area.empty() ? CellRectangle{} : area;
  const std::array<std::uint16_t, 4> values{visible.x, visible.y, visible.width, visible.height};
  for (const auto value : values) {
    write(value);
  }
}

}

int main() {
  try {
    while (std::getchar() != EOF) {
      const auto width = read<std::uint16_t>();
      const auto height = read<std::uint16_t>();
      const auto geometry = NamePromptGeometry::measure({.width = width, .height = height});
      for (const auto area : {geometry.bounds, geometry.title, geometry.field, geometry.footer}) {
        writeRectangle(area);
      }
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
