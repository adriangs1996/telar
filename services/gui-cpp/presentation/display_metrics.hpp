#pragma once

#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace telar::gui {

struct DisplayMetrics {
  double density = 1;
  Viewport viewport{};
  ChromeMetrics chrome{};
  WindowGeometry geometry{};

  [[nodiscard]] static DisplayMetrics resolve(const Configuration &configuration, Viewport logical_viewport, const CellMetrics &cells, double density) {
    if (!std::isfinite(density) || density <= 0 || density > Viewport::maximum_scale) {
      throw std::invalid_argument{"InvalidDisplayDensity"};
    }

    const Viewport physical{
        .width = physicalExtent(logical_viewport.width, density),
        .height = physicalExtent(logical_viewport.height, density),
        .scale = static_cast<float>(density),
        .controls = physicalExtent(logical_viewport.controls, density),
    };
    const auto chrome = ChromeMetrics::resolve(configuration, physical, cells);

    return {.density = density, .viewport = physical, .chrome = chrome, .geometry = WindowGeometry::measure(configuration, physical, cells, chrome)};
  }

private:
  [[nodiscard]] static std::uint32_t physicalExtent(std::uint32_t logical, double density) {
    const auto extent = std::round(logical * density);
    if (extent > std::numeric_limits<std::uint32_t>::max()) {
      throw std::out_of_range{"DisplayExtentOutOfRange"};
    }

    return static_cast<std::uint32_t>(extent);
  }
};

}
