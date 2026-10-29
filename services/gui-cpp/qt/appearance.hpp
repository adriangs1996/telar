#pragma once

#include "core/theme_values.hpp"
#include <QtCore/qnamespace.h>

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
