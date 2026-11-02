#pragma once

namespace telar::gui {

[[nodiscard]] constexpr float smoothstep(float position) noexcept {
  constexpr float quadratic_weight = 3;
  constexpr float cubic_weight = 2;

  return position * position * (quadratic_weight - (cubic_weight * position));
}

}
