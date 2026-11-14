export module telar.gui.platform.secure_random;

import std;

export {
  namespace telar::gui::platform {

    // The kernel's random bytes, as everything in telar draws them.
    struct SecureRandom {
      static void fill(std::span<std::uint8_t> output) noexcept;
    };

  }
}
