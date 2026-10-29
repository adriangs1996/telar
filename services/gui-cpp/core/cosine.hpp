#pragma once

#include <cmath>
#include <concepts>

namespace telar::gui {

template <typename Function>
concept Cosine = requires(float angle) {
  { Function::evaluate(angle) } noexcept -> std::same_as<float>;
};

struct StandardCosine {
  [[nodiscard]] static float evaluate(float angle) noexcept {
    return std::cos(angle);
  }
};

}
