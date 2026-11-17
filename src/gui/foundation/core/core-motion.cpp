module telar.gui.foundation.core;

import std;

namespace telar::gui::inline foundation::inline core {

  float StandardCosine::evaluate(float angle) noexcept {
    return std::cos(angle);
  }

  float ProgressCosine::evaluate(float angle) noexcept {
#ifdef __APPLE__
    return std::cos(angle);
#else
    return static_cast<float>(std::cos(static_cast<double>(angle)));
#endif
  }

}
