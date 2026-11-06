#include "assertions.hpp"
#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/agent_card_geometry.hpp"
#include "presentation/display_metrics.hpp"
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <type_traits>

namespace {

using namespace telar::gui;
using telar::gui::test::require;

static_assert(std::is_trivially_copyable_v<DisplayMetrics>);

void textRowsResolveInPhysicalPixels() {
  const Configuration configuration;
  const CellMetrics cells;
  constexpr Viewport logical{.width = 800, .height = 500};
  constexpr double density = 2;
  const auto display = DisplayMetrics::resolve(configuration, logical, cells, density);
  const auto card = AgentCardGeometry::derive(display.chrome);
  constexpr std::uint16_t expected_small_pixels = 22;
  constexpr float expected_small_row = 29;
  constexpr float expected_card_height = 136;
  constexpr Viewport expected{.width = 1600, .height = 1000, .scale = density};
  require(display.viewport == expected, "logical view dimensions must become physical dimensions once");
  require(display.chrome.small == expected_small_pixels && card.small_row == expected_small_row, "a doubled small label needs the original 29-pixel line box");
  require(card.height() == expected_card_height, "complete card height must sum physical line boxes before projection");
}

void fractionalDensityPreservesPhysicalRounding() {
  Configuration configuration;
  const CellMetrics cells;
  constexpr float font_size = 17;
  configuration.font.size = font_size;
  constexpr Viewport logical{.width = 801, .height = 503, .controls = 25};
  constexpr double density = 1.25;
  const auto display = DisplayMetrics::resolve(configuration, logical, cells, density);
  constexpr Viewport expected{.width = 1001, .height = 629, .scale = density, .controls = 31};
  constexpr std::uint16_t expected_small = 14;
  constexpr std::uint16_t expected_title = 16;
  require(display.viewport == expected, "frame and control extents must round at the physical pixel boundary");
  require(display.chrome.small == expected_small && display.chrome.title == expected_title, "chrome text must round after density independently of the terminal font");
}

void invalidDensityAndUnrepresentableExtentsAreRejected() {
  const Configuration configuration;
  const CellMetrics cells;
  constexpr Viewport logical{.width = 800, .height = 500};
  for (const auto density : {0.0, -1.0, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()}) {
    bool rejected = false;
    try {
      static_cast<void>(DisplayMetrics::resolve(configuration, logical, cells, density));
    } catch (const std::invalid_argument &) {
      rejected = true;
    }

    require(rejected, "invalid display density must fail before any floating-to-integer conversion");
  }

  bool rejected = false;
  try {
    static_cast<void>(DisplayMetrics::resolve(configuration, {.width = std::numeric_limits<std::uint32_t>::max(), .height = 1}, cells, 2));
  } catch (const std::out_of_range &) {
    rejected = true;
  }

  require(rejected, "a physical viewport must fit the original unsigned extent type");
}
}

int main() try {
  textRowsResolveInPhysicalPixels();
  fractionalDensityPreservesPhysicalRounding();
  invalidDensityAndUnrepresentableExtentsAreRejected();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
