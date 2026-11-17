#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cmath>
#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  template <typename Exception, typename Operation>
  void rejects(Operation&& operation) {
    bool rejected = false;

    try {
      std::forward<Operation>(operation)();
    } catch (const Exception&) {
      rejected = true;
    }

    check(rejected, "Invalid font geometry must be rejected before conversion");
  }

  void fixedPointRounding() {
    constexpr std::int64_t fixed_unit = 64;
    constexpr std::int64_t rounding_radius = 8192;

    for (auto value = -rounding_radius; value <= rounding_radius; ++value) {
      const auto expected = static_cast<std::int32_t>(std::round(static_cast<double>(value) / fixed_unit));

      check(FontMetrics::roundFixed(value) == expected, "Font fixed-point rounding must preserve both signs and half-pixel ties");
    }

    constexpr auto largest = std::numeric_limits<std::int32_t>::max();
    constexpr auto smallest = std::numeric_limits<std::int32_t>::min();

    check(FontMetrics::roundFixed(static_cast<std::int64_t>(largest) * fixed_unit) == largest, "The largest representable font metric must remain valid");
    check(FontMetrics::roundFixed(static_cast<std::int64_t>(smallest) * fixed_unit) == smallest, "The smallest representable font metric must remain valid");
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

    check(grid.width == expected_width && grid.height == expected_height, "Spacing must round complete physical cell dimensions");
    check(grid.baseline == expected_baseline, "Odd leading must preserve its half-pixel baseline");
    check(grid.box_stroke == metrics.box_stroke, "A physical font stroke must survive grid resolution");
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

  const telar::testing::Case case_fixed_point_rounding{"font_grid.fixed_point_rounding", fixedPointRounding};
  const telar::testing::Case case_physical_grid_keeps_half_pixels{"font_grid.physical_grid_keeps_half_pixels", physicalGridKeepsHalfPixels};
  const telar::testing::Case case_invalid_geometry{"font_grid.invalid_geometry", invalidGeometry};

}
