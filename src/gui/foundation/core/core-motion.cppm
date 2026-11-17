export module telar.gui.foundation.core:motion;

import std;

// Interface: core/cosine.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    template <typename Function>
    concept Cosine = requires(float angle) {
      { Function::evaluate(angle) } noexcept -> std::same_as<float>;
    };

    struct StandardCosine {
      [[nodiscard]] static float evaluate(float angle) noexcept;
    };

  }
}

// Interface: core/smoothstep.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    [[nodiscard]] constexpr float smoothstep(float position) noexcept {
      constexpr float quadratic_weight = 3;
      constexpr float cubic_weight = 2;

      return position * position * (quadratic_weight - (cubic_weight * position));
    }

  }
}

export {
  namespace telar::gui::inline foundation::inline core {

    struct ProgressCosine {
      [[nodiscard]] static float evaluate(float angle) noexcept;
    };

  }
}
