#pragma once

#include "chrome_style.hpp"

namespace telar::gui {

struct FormButtonStyle {
  static constexpr float radius = ChromeStyle::control_radius;
  static constexpr float disabled_alpha = 0.4F;
  static constexpr float pressed_alpha = 0.8F;
};

}
