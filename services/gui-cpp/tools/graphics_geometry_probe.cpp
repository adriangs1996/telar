#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_messages.hpp"
#include <limits>
#include <cstddef>
#include "probe_graphics.hpp"
#include "probe_io.hpp"
#include <array>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <tuple>



import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.graphics.texture_cache;

namespace {

using namespace telar::gui;

enum class GeometryOperation : unsigned char {
  placement,
  draw,
  begin_frame,
};

Rect readRect() {
  const auto x = probe::read<float>();
  const auto y = probe::read<float>();
  const auto width = probe::read<float>();
  const auto height = probe::read<float>();

  return {.x = x, .y = y, .width = width, .height = height};
}

void executeDraw(ImageDrawBudget &budget) {
  const ImageGeometry geometry{.source = readRect(), .destination = readRect()};
  const auto bounds = readRect();
  const auto handle = probe::read<std::uint32_t>();
  const auto accepted = budget.used() != ImageDrawBudget::capacity;
  const auto visible = accepted ? geometry.clipped(bounds) : ImageGeometry{};
  const auto drawn = !visible.destination.empty();
  if (drawn) {
    std::ignore = budget.take();
  }

  probe::write(static_cast<std::uint8_t>(accepted));
  probe::write(static_cast<std::uint32_t>(budget.used()));
  probe::write(drawn ? handle : 0U);
  const std::array values{visible.destination.x, visible.destination.y, visible.destination.width, visible.destination.height, visible.source.x, visible.source.y, visible.source.right(), visible.source.bottom()};
  for (const auto value : values) {
    probe::write(value);
  }
}

void executePlacement() {
  const auto image = probe::readImage();
  const auto placement = probe::readPlacement();
  const auto texture_width = probe::read<std::uint32_t>();
  const auto texture_height = probe::read<std::uint32_t>();
  const auto cell_width = probe::read<std::uint32_t>();
  const auto cell_height = probe::read<std::uint32_t>();
  const auto scale = probe::read<float>();
  const Point cell{.x = static_cast<float>(cell_width) / scale, .y = static_cast<float>(cell_height) / scale};
  const auto geometry = ImageGeometry::resolve(placement, image, cell, scale);
  const auto box = ImageDisplayBox::resolve(placement, ImageSourceRect::resolve(placement, image), {.width = cell_width, .height = cell_height});
  const auto source = ImageGeometry::textureSource(geometry.source, {.width = static_cast<float>(texture_width), .height = static_cast<float>(texture_height)});
  probe::write(box.x);
  probe::write(box.y);
  probe::write(box.width);
  probe::write(box.height);
  probe::write(source.x / static_cast<float>(texture_width));
  probe::write(source.y / static_cast<float>(texture_height));
  probe::write((source.x + source.width) / static_cast<float>(texture_width));
  probe::write((source.y + source.height) / static_cast<float>(texture_height));
}

}

int main() {
  try {
    ImageDrawBudget budget;
    for (auto value = std::getchar(); value != EOF; value = std::getchar()) {
      switch (static_cast<GeometryOperation>(value)) {
      case GeometryOperation::placement:
        executePlacement();
        break;
      case GeometryOperation::draw:
        executeDraw(budget);
        break;
      case GeometryOperation::begin_frame:
        budget = {};
        break;
      default:
        throw std::runtime_error{"Unknown image geometry probe operation"};
      }
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
