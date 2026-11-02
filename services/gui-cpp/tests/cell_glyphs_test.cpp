#include "core/geometry.hpp"
#include "core/unicode_scalar.hpp"
#include "terminal/glyphs/alpha_raster.hpp"
#include "terminal/glyphs/block.hpp"
#include "terminal/glyphs/box.hpp"
#include "terminal/glyphs/box_curve.hpp"
#include "terminal/glyphs/box_metrics.hpp"
#include "terminal/glyphs/box_stroke.hpp"
#include "terminal/glyphs/braille.hpp"
#include "terminal/glyphs/curve_cache.hpp"
#include "terminal/glyphs/symbol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>

namespace {

using namespace telar::gui;
using namespace telar::gui::glyphs;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void parsing() {
  for (const auto first : {Symbol::first_box, Symbol::first_block, Symbol::first_braille}) {
    const auto bytes = Utf8Scalar::encode(first);
    const auto glyph = Symbol::parse(bytes.view());
    require(glyph && glyph->codepoint == first, "bare procedural codepoints must retain their identity");
  }

  for (const auto *text : {"x", "", "\xe2\xa0\x80\xcc\x81", "\xe2\xa0", "\xe2\xa0x", "\xe2\x16\x80"}) {
    require(!Symbol::parse(text), "incomplete, invalid and combining sequences must remain in the text path");
  }
}

template <typename Paint>
void verifyBounds(const Paint &paint, Rect cell) {
  for (const auto rectangle : paint.rectangles()) {
    require(rectangle.x >= cell.x && rectangle.y >= cell.y && rectangle.right() <= cell.right() && rectangle.bottom() <= cell.bottom(), "procedural ink must remain inside its complete cell");
    require(!rectangle.empty(), "procedural ink must not retain empty rectangles");
  }
}

void brailleGeometry() {
  constexpr Rect cell{.x = 10, .y = 20, .width = 8, .height = 16};
  const auto blank = Braille::draw(cell, 0);
  require(blank.rectangles().empty(), "blank Braille must keep its advance without drawing ink");
  const auto full = Braille::draw(cell, std::numeric_limits<std::uint8_t>::max());
  require(full.rectangles().size() == Braille::dot_count, "each set Braille bit must own one dot");
  for (std::size_t bit = 0; bit < Braille::dot_count; ++bit) {
    const auto single = Braille::draw(cell, static_cast<std::uint8_t>(1U << bit));
    require(single.rectangles().size() == 1 && single.rectangles().front() == full.rectangles()[bit], "bit positions must preserve Unicode Braille numbering");
  }

  for (const auto extent : {0.0F, 0.5F, 1.0F, 2.0F, 3.0F, 9.0F}) {
    const Rect small{.x = 1, .y = 2, .width = extent, .height = extent};
    verifyBounds(Braille::draw(small, std::numeric_limits<std::uint8_t>::max()), small);
  }
}

void blockGeometry() {
  constexpr Rect cell{.x = 10, .y = 20, .width = 9, .height = 17};
  for (std::uint32_t codepoint = Symbol::first_block; codepoint <= Symbol::last_block; ++codepoint) {
    verifyBounds(Block::draw(cell, codepoint), cell);
  }

  constexpr std::uint32_t upper_half = 0x2580;
  constexpr std::uint32_t lower_half = 0x2584;
  const auto upper = Block::draw(cell, upper_half).rectangles().front();
  const auto lower = Block::draw(cell, lower_half).rectangles().front();
  require(upper.bottom() == lower.y && upper.height + lower.height == cell.height, "opposite half blocks must tile odd pixel extents exactly");
  constexpr std::uint32_t light_shade = 0x2591;
  constexpr float expected_coverage = 0.25F;
  const auto shade = Block::draw(cell, light_shade);
  require(shade.coverage() == expected_coverage && shade.rectangles().front() == cell, "shades must blend one complete cell at their coverage");
}

void invalidBounds() {
  constexpr float extent_limit = std::numeric_limits<std::uint16_t>::max();
  const std::array<Rect, 4> invalid{{{.width = -1}, {.width = std::numeric_limits<float>::infinity()}, {.x = std::numeric_limits<float>::quiet_NaN()}, {.height = extent_limit + 1}}};
  for (const auto cell : invalid) {
    bool rejected = false;
    try {
      static_cast<void>(Braille::draw(cell, 1));
    } catch (const std::invalid_argument &) {
      rejected = true;
    }

    require(rejected, "invalid cell geometry must fail before integer projection");
  }
}

void verifyDisjoint(std::span<const Rect> rectangles) {
  for (std::size_t index = 0; index < rectangles.size(); ++index) {
    for (const auto other : rectangles.subspan(index + 1)) {
      require(rectangles[index].intersect(other).empty(), "box intersections must blend each pixel at most once");
    }
  }
}

void boxGeometry() {
  constexpr std::array<float, 5> extents{0, 0.5F, 2, 9, 17};
  for (const auto extent : extents) {
    const Rect cell{.x = 10, .y = 20, .width = extent, .height = 2 * extent};
    for (auto codepoint = Symbol::first_box; codepoint <= Symbol::last_box; ++codepoint) {
      if (codepoint >= Symbol::first_box_curve && codepoint <= Symbol::last_box_curve) {
        continue;
      }

      const auto ink = Box::draw(codepoint, cell, 1);
      verifyBounds(ink, cell);
      verifyDisjoint(ink.rectangles());
    }
  }

  constexpr Rect tiny{.width = 2, .height = 2};
  constexpr std::uint32_t light_horizontal = 0x2500;
  constexpr std::uint32_t double_horizontal = 0x2550;
  const auto single = Box::draw(light_horizontal, tiny, 1);
  const auto doubled = Box::draw(double_horizontal, tiny, 1);
  require(single.rectangles().size() == doubled.rectangles().size() && single.rectangles().front() == doubled.rectangles().front(), "tiny cells must replace a clipped double stroke with one visible stroke");
}

void physicalBoxStroke() {
  constexpr BoxStroke design{.units_per_em = 1000, .underline_thickness = 50};
  constexpr std::uint16_t normal_height = 15;
  constexpr std::uint16_t doubled_height = 30;
  constexpr std::uint16_t quadrupled_height = 60;
  require(design.pixels(normal_height) == 1 && design.pixels(doubled_height) == 2 && design.pixels(quadrupled_height) == 3, "box thickness must scale the design metric before rounding to physical pixels");
  constexpr BoxStroke negative{.units_per_em = 1000, .underline_thickness = -1};
  require(negative.pixels(doubled_height) == 2 && BoxStroke{}.pixels(normal_height) == 1, "missing or nonpositive design metrics must use the original pixel-height fallback");
}

void curveRaster() {
  constexpr std::uint16_t width = 9;
  constexpr std::uint16_t height = 17;
  constexpr std::size_t stride = width + 4;
  constexpr std::size_t guard_bytes = 13;
  constexpr std::uint8_t guard = 0xa5;
  std::array<std::uint8_t, (stride * height) + guard_bytes> pixels{};
  for (std::size_t index = 0; index < BoxCurve::shape_count; ++index) {
    pixels.fill(guard);
    const BoxCurve curve{static_cast<BoxCurve::Shape>(index), {.width = width, .height = height}, 1};
    curve.rasterize({.pixels = pixels, .stride = stride, .width = width, .height = height});
    bool ink = false;
    for (std::size_t row = 0; row < height; ++row) {
      const auto line = std::span{pixels}.subspan(row * stride, width);
      ink = ink || std::ranges::any_of(line, [](auto alpha) {
              return alpha != 0;
            });
      const auto padding = std::span{pixels}.subspan((row * stride) + width, stride - width);
      require(std::ranges::all_of(padding, [](auto value) {
                return value == guard;
              }),
              "curve rasterization must preserve row padding");
    }

    require(ink, "each curve must rasterize visible ink");
    require(std::ranges::all_of(std::span{pixels}.last(guard_bytes), [](auto value) {
              return value == guard;
            }),
            "curve rasterization must preserve the storage guard");
  }
}

void invalidRasters() {
  constexpr std::uint8_t guard = 0xa5;
  constexpr std::size_t storage_capacity = 16;
  std::array<std::uint8_t, storage_capacity> pixels{};
  pixels.fill(guard);
  const BoxCurve curve{BoxCurve::Shape::diagonal_cross, {.width = 8, .height = 16}, 1};
  const std::array<AlphaRaster, 3> invalid{{{.pixels = pixels, .stride = 0, .width = 1, .height = 1}, {.pixels = pixels, .stride = 17, .width = 17, .height = 1}, {.pixels = pixels, .stride = std::numeric_limits<std::size_t>::max(), .width = 1, .height = 2}}};
  for (const auto raster : invalid) {
    bool rejected = false;
    try {
      curve.rasterize(raster);
    } catch (const std::invalid_argument &) {
      rejected = true;
    }

    require(rejected, "invalid raster storage must fail before writing or multiplying strides");
    require(std::ranges::all_of(pixels, [](auto value) {
              return value == guard;
            }),
            "rejected rasters must preserve all borrowed bytes");
  }
}

void emptyCurvesClearActivePixels() {
  constexpr std::uint8_t guard = 0xa5;
  constexpr std::size_t storage_capacity = 8;
  constexpr std::uint16_t width = 2;
  constexpr std::uint16_t height = 2;
  constexpr std::size_t stride = width + 1;
  std::array<std::uint8_t, storage_capacity> pixels{};
  constexpr auto smallest = std::numeric_limits<float>::denorm_min();
  for (const auto extent : {0.0F, smallest}) {
    pixels.fill(guard);
    const BoxCurve curve{BoxCurve::Shape::diagonal_cross, {.width = extent, .height = extent}, 1};
    curve.rasterize({.pixels = pixels, .stride = stride, .width = width, .height = height});
    require(pixels[0] == 0 && pixels[1] == 0 && pixels[stride] == 0 && pixels[stride + 1] == 0, "empty or underflowed geometry must clear only the active raster");
    require(pixels[width] == guard && pixels[stride + width] == guard && pixels.back() == guard, "empty curves must preserve padding and trailing storage");
  }
}

void curveCacheKeepsReferences() {
  using Cache = CurveCache<unsigned>;
  Cache cache;
  unsigned builds = 0;
  const auto build = [&] -> std::optional<unsigned> {
    return ++builds;
  };
  constexpr BoxCurve::Shape shape = BoxCurve::Shape::rounded_down_right;
  constexpr Rect cell{.width = 9, .height = 17};
  const auto metrics = BoxMetrics::resolve(cell, 1);
  const auto *retained = cache.resolve(metrics, shape, build);
  require(retained != nullptr && *retained == 1, "the first curve must own one cache entry");
  require(cache.resolve(metrics, shape, build) == retained && builds == 1, "repainting a curve must reuse its admitted mask");
  for (std::size_t index = 1; index < Cache::capacity; ++index) {
    const Rect extent{.width = cell.width + static_cast<float>(index), .height = cell.height};
    require(cache.resolve(BoxMetrics::resolve(extent, 1), shape, build) != nullptr, "the cache must admit its complete mask capacity");
  }

  constexpr Rect extra{.width = 100, .height = 200};
  require(cache.resolve(BoxMetrics::resolve(extra, 1), shape, build) == nullptr && builds == Cache::capacity, "full caches must request the reserved fallback without more rasterization");
  require(*retained == 1 && cache.resolve(metrics, shape, build) == retained, "saturation must preserve every retained mask identity");
}

void curveCacheMemoizesFailure() {
  CurveCache<unsigned> cache;
  unsigned attempts = 0;
  const auto metrics = BoxMetrics::resolve({.width = 9, .height = 17}, 1);
  constexpr BoxCurve::Shape shape = BoxCurve::Shape::diagonal_cross;
  const auto failed = [&] -> std::optional<unsigned> {
    ++attempts;

    return std::nullopt;
  };
  require(cache.resolve(metrics, shape, failed) == nullptr, "a failed mask must request the reserved fallback");
  require(cache.resolve(metrics, shape, failed) == nullptr && attempts == 1 && cache.size() == 1, "a failed admission must not be rasterized again");
  cache.reset();
  require(cache.resolve(metrics, shape, failed) == nullptr && attempts == 2, "a new font generation must release old admissions");
}

}

int main() {
  try {
    parsing();
    brailleGeometry();
    blockGeometry();
    boxGeometry();
    physicalBoxStroke();
    curveRaster();
    invalidRasters();
    emptyCurvesClearActivePixels();
    curveCacheKeepsReferences();
    curveCacheMemoizesFailure();
    invalidBounds();
    std::puts("gui-cell-glyphs: passed");
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
