#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <cstdio>
#include <exception>
#include <iostream>
#include <utility>



import telar.gui.core.metrics;
import telar.gui.terminal.font_grid;

namespace {

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <typename Exception, typename Operation>
void rejects(Operation &&operation) {
  bool rejected = false;
  try {
    std::forward<Operation>(operation)();
  } catch (const Exception &) {
    rejected = true;
  }

  require(rejected, "Invalid font geometry must be rejected before conversion");
}

void fixedPointRounding() {
  constexpr std::int64_t fixed_unit = 64;
  constexpr std::int64_t rounding_radius = 8192;
  for (auto value = -rounding_radius; value <= rounding_radius; ++value) {
    const auto expected = static_cast<std::int32_t>(std::round(static_cast<double>(value) / fixed_unit));
    require(FontMetrics::roundFixed(value) == expected, "Font fixed-point rounding must preserve both signs and half-pixel ties");
  }

  constexpr auto largest = std::numeric_limits<std::int32_t>::max();
  constexpr auto smallest = std::numeric_limits<std::int32_t>::min();
  require(FontMetrics::roundFixed(static_cast<std::int64_t>(largest) * fixed_unit) == largest, "The largest representable font metric must remain valid");
  require(FontMetrics::roundFixed(static_cast<std::int64_t>(smallest) * fixed_unit) == smallest, "The smallest representable font metric must remain valid");
  rejects<std::out_of_range>([] {
    static_cast<void>(FontMetrics::roundFixed(std::numeric_limits<std::int64_t>::max()));
  });
  rejects<std::out_of_range>([] {
    static_cast<void>(FontMetrics::roundFixed(std::numeric_limits<std::int64_t>::min()));
  });
}

void physicalGridKeepsHalfPixels() {
  constexpr FontMetrics metrics{.ascender = 16, .line_height = 20, .maximum_advance = 9, .box_stroke = 2};
  FontConfiguration configuration;
  constexpr float expanded_line_height = 1.05F;
  constexpr float half_pixel_spacing = 0.5F;
  configuration.line_height = expanded_line_height;
  configuration.letter_spacing = half_pixel_spacing;
  const auto grid = FontGrid::resolve(metrics, configuration, 1);
  constexpr std::uint16_t expected_width = 10;
  constexpr std::uint16_t expected_height = 21;
  constexpr float expected_baseline = 16.5F;
  require(grid.width == expected_width && grid.height == expected_height, "Spacing must round complete physical cell dimensions");
  require(grid.baseline == expected_baseline, "Odd leading must preserve its half-pixel baseline");
  require(grid.box_stroke == metrics.box_stroke, "A physical font stroke must survive grid resolution");
}

void invalidGeometry() {
  FontConfiguration configuration;
  constexpr FontMetrics metrics;
  constexpr std::array scales{0.0F, -1.0F, Viewport::maximum_scale + 1, std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN()};
  for (const auto scale : scales) {
    rejects<std::invalid_argument>([&] {
      static_cast<void>(FontGrid::resolve(metrics, configuration, scale));
    });
  }

  constexpr std::array invalid_values{0.0F, -1.0F, std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN()};
  for (const auto value : invalid_values) {
    configuration.size = value;
    rejects<std::invalid_argument>([&] {
      static_cast<void>(FontGrid::pixelHeight(configuration, 1));
    });
  }

  configuration = {};
  configuration.letter_spacing = FontConfiguration::minimum_letter_spacing;
  rejects<std::invalid_argument>([&] {
    static_cast<void>(FontGrid::resolve(metrics, configuration, 1));
  });
  configuration = {};
  configuration.line_height = std::numeric_limits<float>::infinity();
  rejects<std::invalid_argument>([&] {
    static_cast<void>(FontGrid::resolve(metrics, configuration, 1));
  });
}

}

int main() {
  try {
    fixedPointRounding();
    physicalGridKeepsHalfPixels();
    invalidGeometry();
    std::puts("gui-font-grid: passed");
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
