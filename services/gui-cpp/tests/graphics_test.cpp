#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "../core/memory.hpp"
#include <string_view>
#include "graphics/placeholder_diacritics.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <limits>
#include "../terminal/screen.hpp"
#include <array>
#include <optional>
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <concepts>
#include <utility>
#include "telar_client/codecs/telar_wire.hpp"
#include <cstddef>
#include <cstdio>
#include <iostream>

#include "core/memory.hpp"
#include "terminal/screen.hpp"


import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.graphics.texture_cache;

namespace {

using namespace telar;
using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

constexpr ImageDescription rgbaSquare(ImageKey key) noexcept {
  constexpr std::uint32_t side = 2;
  constexpr std::uint64_t channels = 4;

  return {.key = key, .format = ImageFormat::rgba, .width = side, .height = side, .byte_len = channels * side * side};
}

void resourceLifetime() {
  SystemAllocator upstream;
  constexpr std::size_t allocation_budget = std::size_t{1} * 1024 * 1024;
  BudgetAllocator memory{upstream, allocation_budget};
  GraphicsBudget budget;

  {
    GraphicsStore store{memory, budget};
    const GraphicsHeader header{.pane_id = 1, .revision = 1};
    store.snapshot({.header = header, .phase = SnapshotPhase::begin});
    const auto description = rgbaSquare({.image_id = 1, .generation = 1});
    store.image({.header = header, .image = description});
    require(budget.used == description.byte_len && !store.findImage({.image_id = 1, .generation = 1})->ready(), "image storage must count incomplete pixels");
    constexpr auto pixels = std::to_array<Byte>({1, 2, 3, 4, 5, 6, 7, 8});
    require(!store.chunk({.header = header, .key = {.image_id = 1, .generation = 1}, .offset = 0, .bytes = pixels}), "partial image must not be published");
    require(store.chunk({.header = header, .key = {.image_id = 1, .generation = 1}, .offset = pixels.size(), .bytes = pixels}), "complete image must become drawable");
    store.snapshot({.header = header, .phase = SnapshotPhase::end});

    store.image({.header = {.pane_id = 1, .revision = 2}, .image = rgbaSquare({.image_id = 1, .generation = 2})});
    require(store.findImage({.image_id = 1, .generation = 1}) == nullptr && store.readyImage({.image_id = 1, .generation = 2}) == nullptr, "replacement must release unreferenced CPU bytes while the renderer retains its own stand-in");
    store.chunk({.header = {.pane_id = 1, .revision = 2}, .key = {.image_id = 1, .generation = 2}, .offset = 0, .bytes = pixels});
    store.chunk({.header = {.pane_id = 1, .revision = 2}, .key = {.image_id = 1, .generation = 2}, .offset = pixels.size(), .bytes = pixels});
    require(store.findImage({.image_id = 1, .generation = 1}) == nullptr && store.takeCredit() == description.byte_len,
            "complete replacement must release the previous generation and its "
            "credit");
    store.erase(GraphicsDeleteImage{.header = {.pane_id = 1, .revision = 3}, .key = {.image_id = 1, .generation = 2}});
    require(budget.used == 0 && store.takeCredit() == description.byte_len, "deletion must release resource credits exactly once");

    store.image({.header = {.pane_id = 1, .revision = 4}, .image = rgbaSquare({.image_id = 2, .generation = 1})});
    bool rejected = false;
    try {
      store.chunk({.header = {.pane_id = 1, .revision = 4}, .key = {.image_id = 2, .generation = 1}, .offset = 3, .bytes = pixels});
    } catch (const EncodingError &) {
      rejected = true;
    }

    require(rejected && !store.findImage({.image_id = 2, .generation = 1})->ready(), "misordered chunks must not expose partial bytes");
  }

  require(memory.liveBytes() == 0 && budget.used == 0, "graphics ownership must release all allocations and budget");
}

void placementGeometry() {
  constexpr std::uint32_t image_width = 640;
  constexpr std::uint32_t image_height = 480;
  constexpr std::uint64_t channels = 4;
  const ImageDescription image{.key = {.image_id = 1, .generation = 1}, .format = ImageFormat::rgba, .width = image_width, .height = image_height, .byte_len = channels * image_width * image_height};
  constexpr Point cell{.x = 16, .y = 32};
  constexpr std::uint32_t columns = 20;
  constexpr std::uint32_t rows = 10;
  constexpr std::uint32_t outside_cell_offset = 100;
  constexpr Rect proportional_size{.width = 320, .height = 240};
  constexpr Rect stretched_size{.width = 320, .height = 320};
  constexpr Rect clipped_placement{.x = 15, .width = 305};
  GraphicsPlacement placement;
  placement.key = image.key;
  placement.columns = columns;
  const auto aspect = ImageGeometry::resolve(placement, image, cell, 1);
  require(aspect.destination.width == proportional_size.width && aspect.destination.height == proportional_size.height, "one requested dimension must preserve aspect ratio");
  placement.rows = rows;
  const auto stretched = ImageGeometry::resolve(placement, image, cell, 1);
  require(stretched.destination.width == stretched_size.width && stretched.destination.height == stretched_size.height, "two requested dimensions must fill the requested cells");
  placement.offset_x = outside_cell_offset;
  const auto clamped = ImageGeometry::resolve(placement, image, cell, 1);
  require(clamped.destination.x == clipped_placement.x && clamped.destination.width == clipped_placement.width, "placement offsets must remain inside the anchor cell");
}

void unicodePlaceholders() {
  constexpr Byte image_id = 9;
  CellValue cell;
  const std::string_view text = "\xf4\x8e\xbb\xae\xcc\x85\xcc\x8d";
  std::ranges::copy(text, cell.text.begin());
  cell.length = static_cast<Byte>(text.size());
  cell.style.foreground = {.kind = CellColor::Kind::rgb, .channels = {0, 0, image_id}};
  const auto parsed = parsePlaceholder(cell);
  if (!parsed) {
    throw std::runtime_error{"The reference placeholder must decode"};
  }

  require(parsed->row == 0 && parsed->column == 1 && parsed->image_low == image_id, "placeholder diacritics and color ids must match the reference table");
  auto run = PlaceholderRun::begin(*parsed, 3);
  PlaceholderCell next;
  next.image_low = image_id;
  require(run.extend(next) && run.width == 2, "omitted marks must continue the previous fragment");
  next.row = 1;
  require(!run.extend(next), "a different explicit row must end the run");

  const ImageDescription image{.key = {.image_id = image_id, .generation = 1}, .format = ImageFormat::rgba, .width = 200, .height = 100, .byte_len = 80000};
  GraphicsPlacement placement;
  placement.columns = 2;
  placement.rows = 2;
  const PlaceholderRun beginning;
  constexpr Point placeholder_cell{.x = 100, .y = 100};
  constexpr float expected_source_width = 100;
  constexpr float expected_source_height = 50;
  constexpr float expected_top_margin = 50;
  const auto first = placeholderGeometry(beginning, placement, image, placeholder_cell, 1);
  require(first.source.width == expected_source_width && first.source.height == expected_source_height && first.destination.y == expected_top_margin, "placeholder aspect fitting must center the image in its cell grid");
}

}

int main() {
  try {
    resourceLifetime();
    placementGeometry();
    unicodePlaceholders();
    std::puts("gui-graphics: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-graphics: " << error.what() << '\n';

    return 1;
  }
}
