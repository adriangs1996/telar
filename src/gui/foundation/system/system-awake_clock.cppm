export module telar.gui.foundation.system:awake_clock;

import std;

export extern "C++" {
  namespace telar::gui::inline foundation::inline system {

    struct AwakeClock {
      [[nodiscard]] static std::uint64_t nowNanoseconds() noexcept;
    };

  }
}
