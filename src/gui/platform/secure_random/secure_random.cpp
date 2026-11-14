module telar.gui.platform.secure_random;

import std;

import telar.platform.primitives;

namespace telar::gui::platform {

  void SecureRandom::fill(std::span<std::uint8_t> output) noexcept {
    runtime::randomBytes(output.data(), output.size());
  }

}
