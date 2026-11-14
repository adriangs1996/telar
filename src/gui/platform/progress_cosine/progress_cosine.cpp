module telar.gui.platform.progress_cosine;

import std;

namespace telar::gui::platform {

  float ProgressCosine::evaluate(float angle) noexcept {
#ifdef __APPLE__
    return std::cos(angle);
#else
    return static_cast<float>(std::cos(static_cast<double>(angle)));
#endif
  }

}
