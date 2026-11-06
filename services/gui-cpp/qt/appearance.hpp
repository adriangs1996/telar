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
#include <QtCore/qnamespace.h>

#pragma once


import telar.gui.core.metrics;

namespace telar::gui::qt {

inline Appearance hostAppearance(Qt::ColorScheme scheme) noexcept {
  switch (scheme) {
  case Qt::ColorScheme::Light:
    return Appearance::light;
  case Qt::ColorScheme::Dark:
    return Appearance::dark;
  case Qt::ColorScheme::Unknown:
    return Appearance::unknown;
  }

  return Appearance::unknown;
}

}
