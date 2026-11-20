export module telar.gui.foundation.core:terminal_size;

import std;

import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar::gui::inline foundation::inline core {

  inline constexpr TerminalSize default_terminal_size{
      .cols = 80,
      .rows = 24,
      .cell_width_px = 9,
      .cell_height_px = 18,
  };

  struct TerminalGrid {
    static constexpr std::uint16_t maximum_dimension = std::numeric_limits<std::uint16_t>::max();
    static constexpr std::size_t maximum_cells = 130359;

    std::uint16_t cell_width_px = default_terminal_size.cell_width_px;
    std::uint16_t cell_height_px = default_terminal_size.cell_height_px;
    double scale = 1;

    bool operator==(const TerminalGrid&) const = default;

    [[nodiscard]] ds::Option<TerminalSize> fit(double width, double height) const noexcept;
  };

}
