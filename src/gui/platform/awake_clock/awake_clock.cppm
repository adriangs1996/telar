export module telar.gui.platform.awake_clock;

import std;

export extern "C++" {
  namespace telar::gui::platform {

    struct AwakeClock {
      [[nodiscard]] static std::uint64_t nowNanoseconds() noexcept;
    };

  }
}
