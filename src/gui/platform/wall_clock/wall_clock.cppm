export module telar.gui.platform.wall_clock;

export import telar.gui.core.unicode_scalar;

export {
  namespace telar::gui::platform {

    struct WallClock {
      [[nodiscard]] static CalendarSample sample() noexcept;
    };

  }
}
