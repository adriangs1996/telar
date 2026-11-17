module telar.gui.foundation.system;

import std;

import telar.platform.primitives;

namespace telar::gui::inline foundation::inline system {

  void SecureRandom::fill(std::span<std::uint8_t> output) noexcept {
    runtime::randomBytes(output.data(), output.size());
  }

}
