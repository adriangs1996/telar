export module telar.gui.foundation.model:pane_layout;

import std;

import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: application/pane_bottom_reservation.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    struct PaneBottomReservation {
      static constexpr std::uint16_t shelf_rows = 6;
      static constexpr std::uint16_t shelf_minimum_rows = 3;
      static constexpr std::uint16_t pane_minimum_rows = 3;

      std::uint64_t pane_id = 0;
      std::uint16_t preferred_height = shelf_rows;
      std::uint16_t minimum_height = shelf_minimum_rows;
      std::uint16_t minimum_pane_height = pane_minimum_rows;

      bool operator==(const PaneBottomReservation&) const = default;
    };

  }
}

// Interface: application/pane_layout.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    class PaneLayout {
    public:
      static constexpr std::size_t maximum_panes = 64;
      static constexpr std::size_t maximum_nodes = (maximum_panes * 2) - 1;
      static constexpr std::uint16_t ratio_maximum = 10000;
      static constexpr std::uint16_t ratio_half = ratio_maximum / 2;
      static constexpr std::uint16_t ratio_minimum = 1000;
      static constexpr std::uint16_t ratio_maximum_split = 9000;
      static constexpr std::uint16_t resize_step = ratio_maximum / 20;

      struct Metrics {
        std::uint8_t border = 1;
        std::uint8_t gap = 1;
        std::uint8_t header = 1;

        [[nodiscard]] std::uint16_t minimumPaneExtent(ClientLayoutAxis axis = ClientLayoutAxis::horizontal) const noexcept;
        [[nodiscard]] CellRectangle content(CellRectangle bounds) const noexcept;

        bool operator==(const Metrics&) const = default;
      };

      struct Placement {
        std::uint64_t pane_id = 0;
        CellRectangle bounds;
        std::uint16_t display_index = 0;
        CellRectangle content;
        bool framed = false;
      };

      struct Divider {
        std::size_t node_index = 0;
        ClientLayoutAxis axis = ClientLayoutAxis::horizontal;
        CellRectangle bounds;
        CellRectangle parent_bounds;
      };

      struct DividerPosition {
        std::size_t node_index;
        std::uint16_t ratio;
      };

      struct FocusRequest {
        std::uint64_t pane_id = 0;
        PaneDirection direction = PaneDirection::right;
        bool fullscreen = false;
      };

      struct SplitBounds {
        CellRectangle existing_content;
        CellRectangle added_content;
      };

      [[nodiscard]] static bool hasBorders(Metrics metrics) noexcept;

      void restore(std::span<const ClientLayoutNode> nodes);
      bool add(std::uint64_t pane_id, ClientLayoutAxis axis, std::uint64_t beside) noexcept;
      bool remove(std::uint64_t pane_id) noexcept;
      void setBottomReservation(ds::Option<PaneBottomReservation> reservation) noexcept;
      [[nodiscard]] CellRectangle reservedArea() const noexcept;
      std::span<const Placement> arrange(CellRectangle bounds, Metrics metrics, ds::Option<std::uint64_t> fullscreen = {}) noexcept;
      [[nodiscard]] std::span<const Divider> dividers() const noexcept;
      [[nodiscard]] ds::Option<SplitBounds> prospectiveSplit(CellRectangle area, ClientLayoutAxis axis, std::uint64_t pane_id, Metrics metrics, ds::Option<std::uint64_t> fullscreen = {}) noexcept;
      bool setSplitRatio(DividerPosition position) noexcept;
      [[nodiscard]] std::uint64_t focusTarget(CellRectangle area, Metrics metrics, FocusRequest request) noexcept;
      bool resize(std::uint64_t pane_id, PaneDirection direction, CellRectangle area, Metrics metrics) noexcept;
      [[nodiscard]] bool contains(std::uint64_t pane_id) const noexcept;
      [[nodiscard]] std::span<const ClientLayoutNode> nodes() const noexcept;
      [[nodiscard]] std::uint64_t firstPane() const noexcept;
      [[nodiscard]] std::uint16_t displayIndex(std::uint64_t pane_id) const noexcept;

    private:
      struct FocusOrigin {
        CellRectangle bounds;
        PaneDirection direction = PaneDirection::right;

        [[nodiscard]] ds::Option<std::uint64_t> score(CellRectangle candidate) const noexcept;
      };

      struct SplitGeometry {
        CellRectangle first;
        CellRectangle second;
        CellRectangle divider;
      };

      void reserveBelowPane(Metrics metrics) noexcept;
      bool moveDivider(std::size_t index, bool decreasing, CellRectangle area, Metrics metrics) noexcept;
      [[nodiscard]] std::uint64_t fullscreenFocusTarget(FocusRequest request) const noexcept;
      [[nodiscard]] std::uint16_t minimumExtent(std::size_t root, ClientLayoutAxis axis, Metrics metrics) const noexcept;
      [[nodiscard]] ds::Option<std::size_t> indexOf(std::uint64_t pane_id) const noexcept;
      [[nodiscard]] std::size_t subtreeEnd(std::size_t beginning) const noexcept;
      static SplitGeometry partition(CellRectangle bounds, const ClientLayoutSplit& split, std::uint16_t gap) noexcept;
      void arrangeNodes(CellRectangle bounds, Metrics metrics) noexcept;

      std::array<ClientLayoutNode, maximum_nodes> nodes_;
      std::array<Placement, maximum_panes> placements_;
      std::array<Divider, maximum_panes - 1> dividers_;
      ds::Option<PaneBottomReservation> reservation_;
      CellRectangle reserved_;
      std::size_t count_ = 0;
      std::size_t placement_count_ = 0;
      std::size_t divider_count_ = 0;
    };

  }
}

// Interface: application/workbench_geometry.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    struct WorkbenchGeometry {
      static constexpr float default_width = default_terminal_size.cols * default_terminal_size.cell_width_px;
      static constexpr float default_height = default_terminal_size.rows * default_terminal_size.cell_height_px;

      Rect area{.width = default_width, .height = default_height};
      TerminalGrid grid;
      PaneLayout::Metrics layout_metrics;

      bool operator==(const WorkbenchGeometry&) const = default;

      // A new pane opens alone in its tab, framed like any other pane.
      [[nodiscard]] ds::Option<TerminalSize> launchSize() const noexcept;
      [[nodiscard]] CellRectangle cellArea() const noexcept;
      [[nodiscard]] ds::Option<TerminalSize> contentSize(CellRectangle content) const noexcept;
      [[nodiscard]] Rect pixels(CellRectangle cells) const noexcept;
    };

  }
}
