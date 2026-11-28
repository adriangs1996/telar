export module telar.gui.tests.controlled_awake_clock;

import std;

export namespace telar::gui::test {

  struct ControlledAwakeClock {
    static void set(std::uint64_t now_ns) noexcept;
  };

}
