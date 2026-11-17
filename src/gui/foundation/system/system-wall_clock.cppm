export module telar.gui.foundation.system:wall_clock;

import telar.gui.foundation.core;

export {
  namespace telar::gui::inline foundation::inline system {

    struct WallClock {
      [[nodiscard]] static CalendarSample sample() noexcept;
    };

  }
}
