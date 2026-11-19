export module telar.gui.foundation.system:awake_clock;

import std;

export namespace telar::gui::inline foundation::inline system {

  extern "C++" struct AwakeClock {
    [[nodiscard]] static std::uint64_t nowNanoseconds() noexcept;
  };

}
