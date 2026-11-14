export module telar.gui.terminal.selection;

import std;

// Interface: terminal/selection.cppm
export {
  namespace telar::gui {

    struct CellSelection {
      int anchor = -1;
      int head = -1;

      bool operator==(const CellSelection&) const = default;

      [[nodiscard]] CellSelection within(std::size_t first, std::size_t count) const noexcept;
      [[nodiscard]] bool contains(std::size_t cell) const noexcept;
    };

  }
}
