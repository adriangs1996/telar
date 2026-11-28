export module telar.gui.foundation.core:wheel;

import std;

export namespace telar::gui::inline foundation::inline core {

  enum class ScrollPhase : std::uint8_t {
    none,
    begin,
    update,
    end,
    cancel,
  };

  struct ScrollSample {
    double delta = 0;
    double cell_height = 1;
    bool precise = false;
    ScrollPhase phase = ScrollPhase::none;
  };

  class WheelAccumulator {
  public:
    static constexpr std::int32_t maximum_lines = 32;
    static constexpr std::int32_t rows_per_line = 3;

    [[nodiscard]] std::int32_t consume(ScrollSample sample) noexcept;
    void reset() noexcept;

  private:
    double remainder_ = 0;
  };

}
