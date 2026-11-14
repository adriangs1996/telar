export module telar.gui.platform.secure_random;

import std;

import telar.platform.primitives;

export {
  namespace telar::gui::platform {

    // The kernel's random bytes, as everything in telar draws them.
    struct SecureRandom {
      inline static void fill(std::span<std::uint8_t> output) noexcept {
        runtime::randomBytes(output.data(), output.size());
      }
    };

  }
}
