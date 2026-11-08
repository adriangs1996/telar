#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.tools.probe_io;
import telar.gui.graphics.placeholder;

namespace {

enum class Operation : std::uint8_t {
  clip,
};
enum class Field : std::uint8_t {
  x,
  y,
  width,
  height,
  u0,
  v0,
  u1,
  v1,
  red,
  green,
  blue,
  alpha,
  radius,
  border_width,
  texture,
  reserved,
  border_red,
  border_green,
  border_blue,
  border_alpha,
  clip_x,
  clip_y,
  clip_width,
  clip_height,
  count,
};

}

int main() {
  try {
    while (true) {
      const auto operation = std::getchar();
      if (operation == EOF) {
        return 0;
      }

      if (operation != static_cast<int>(Operation::clip)) {
        throw std::runtime_error{"UnknownClipOperation"};
      }

      const auto values = telar::gui::probe::read<std::array<float, static_cast<std::size_t>(Field::count)>>();
      const auto value = [&values](Field field) {
        return values[static_cast<std::size_t>(field)];
      };
      const telar::gui::RoundedRectanglePaint paint{.origin = {.x = value(Field::x), .y = value(Field::y)}, .shape = {.size = {.x = value(Field::width), .y = value(Field::height)}, .style = {.fill = {.r = value(Field::red), .g = value(Field::green), .b = value(Field::blue), .a = value(Field::alpha)}, .border = {.r = value(Field::border_red), .g = value(Field::border_green), .b = value(Field::border_blue), .a = value(Field::border_alpha)}, .radius = value(Field::radius), .border_width = value(Field::border_width)}}};
      const auto clipped = paint.clipped({.x = value(Field::clip_x), .y = value(Field::clip_y), .width = value(Field::clip_width), .height = value(Field::clip_height)});
      const auto &style = clipped.shape.style;
      telar::gui::probe::write(std::array{clipped.origin.x, clipped.origin.y, clipped.shape.size.x, clipped.shape.size.y, style.fill.r, style.fill.g, style.fill.b, style.fill.a, style.radius, style.border_width, style.border.r, style.border.g, style.border.b, style.border.a});
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
