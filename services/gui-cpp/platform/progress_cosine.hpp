#pragma once

#include <cmath>

namespace telar::gui::platform {

struct ProgressCosine {
  [[nodiscard]] static float evaluate(float angle) noexcept {
#ifdef __APPLE__
    return std::cos(angle);
#else
    return static_cast<float>(std::cos(static_cast<double>(angle)));
#endif
  }
};

}
