export module telar.gui.platform.progress_cosine;

import std;

export {
  namespace telar::gui::platform {

    struct ProgressCosine {
      [[nodiscard]] inline static float evaluate(float angle) noexcept {
#ifdef __APPLE__
        return std::cos(angle);
#else
        return static_cast<float>(std::cos(static_cast<double>(angle)));
#endif
      }
    };

  }
}
