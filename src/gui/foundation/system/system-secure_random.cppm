export module telar.gui.foundation.system:secure_random;

import std;

export {
  namespace telar::gui::inline foundation::inline system {

    // The kernel's random bytes, as everything in telar draws them.
    struct SecureRandom {
      static void fill(std::span<std::uint8_t> output) noexcept;
    };

  }
}
