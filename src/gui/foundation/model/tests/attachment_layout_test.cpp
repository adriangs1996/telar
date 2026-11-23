#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

import telar.testing;
import telar.gui.foundation.model;
import telar.gui.foundation.core;
import telar.base.ds;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using telar::testing::check;

  constexpr std::uint64_t first_pane = 1;
  constexpr std::uint64_t second_pane = 2;
  constexpr std::uint16_t columns = 80;
  constexpr std::uint16_t tall_rows = 24;

  void reservationsRespectMinimumsAndBorderlessContent() {
    PaneLayout layout;

    check(layout.add(first_pane, ClientLayoutAxis::horizontal, 0), "the first pane must exist");
    layout.setBottomReservation(PaneBottomReservation{.pane_id = first_pane});
    constexpr auto maximum_test_rows = PaneBottomReservation::shelf_rows + PaneBottomReservation::pane_minimum_rows;

    for (std::uint16_t rows = 0; rows <= maximum_test_rows; ++rows) {
      const auto views = layout.arrange({.width = columns, .height = rows}, {.border = 0});

      check(views.size() == 1, "reservation must preserve the single pane");
      const auto available = rows > PaneBottomReservation::pane_minimum_rows ? rows - PaneBottomReservation::pane_minimum_rows : 0;
      const auto wanted = std::min<unsigned>(PaneBottomReservation::shelf_rows, available);
      const auto reserved = wanted >= PaneBottomReservation::shelf_minimum_rows ? wanted : 0;

      check(views.front().bounds.height == rows - reserved && views.front().content == views.front().bounds, "small borderless panes must preserve their minimum content and use whole cells");
      check(layout.reservedArea().height == reserved, "insufficient shelf height must reserve nothing");
    }

    layout.setBottomReservation(ds::none);
    const auto restored = layout.arrange({.width = columns, .height = tall_rows}, {});

    check(restored.front().bounds.height == tall_rows && layout.reservedArea().empty(), "removing the shelf must restore every terminal row");
  }

  void reservationsLeaveSiblingGeometryAndSplitContentConsistent() {
    PaneLayout layout;

    check(layout.add(first_pane, ClientLayoutAxis::horizontal, 0) && layout.add(second_pane, ClientLayoutAxis::horizontal, first_pane), "the two-pane fixture must exist");
    constexpr CellRectangle host{.width = columns, .height = tall_rows};
    const auto before = layout.arrange(host, {});
    const auto sibling = before.back();
    const auto first = before.front();

    layout.setBottomReservation(PaneBottomReservation{.pane_id = first_pane});
    const auto after = layout.arrange(host, {});

    check(after.back().bounds == sibling.bounds && after.back().content == sibling.content, "another pane's shelf must preserve sibling bounds and content");
    check(after.front().bounds.height == first.bounds.height - PaneBottomReservation::shelf_rows && after.front().content == PaneLayout::Metrics{}.content(after.front().bounds), "framed panes must recompute their inner terminal after reservation");
    check(layout.reservedArea().y == after.front().bounds.bottom(), "the shelf must begin exactly below the shortened outer pane");
    const auto split = layout.prospectiveSplit(host, ClientLayoutAxis::horizontal, first_pane, {});

    check(split && split->existing_content.height == after.front().content.height && split->added_content.height == after.front().content.height, "prospective horizontal splits must use the same reserved height as the visible terminal");
  }

  // Under its last row a pane keeps no row of cells: its frame takes the room the gap's row
  // leaves it, and the workbench keeps as much at its foot for the panes there. Without gaps
  // a pane has neither, and keeps the row.
  void panesKeepNoRowUnderTheirContentBesideGaps() {
    constexpr CellRectangle bounds{.x = 3, .y = 5, .width = columns, .height = tall_rows};
    constexpr PaneLayout::Metrics gapped{.header = 2};
    constexpr PaneLayout::Metrics gapless{.gap = 0, .header = 2};

    check(gapped.content(bounds) == CellRectangle{.x = 4, .y = 7, .width = columns - 2, .height = tall_rows - 2}, "a pane beside gaps must give its content every row under its header");
    check(gapless.content(bounds) == CellRectangle{.x = 4, .y = 7, .width = columns - 2, .height = tall_rows - 3}, "a pane without gaps must keep a row under its content");
    check(gapped.minimumPaneExtent(ClientLayoutAxis::vertical) == 3 && gapless.minimumPaneExtent(ClientLayoutAxis::vertical) == 4 && gapped.minimumPaneExtent() == 3, "a pane must have room for its frame and a cell");
    check(gapped.content({.width = 2, .height = tall_rows}).empty() && gapped.content({.width = columns, .height = 2}).empty(), "a pane too small for its frame must have no content");
    check(PaneLayout::Metrics{.border = 0}.content(bounds) == bounds, "a pane without borders must be all content");
  }

  void workbenchKeepsRoomAtItsFootForFramedPanes() {
    constexpr TerminalGrid grid{.cell_width_px = 8, .cell_height_px = 19, .scale = 1};
    constexpr float width = 800;
    // Ten rows and what is left of an eleventh: less than the foot, then enough for it.
    constexpr float short_of_foot = (10 * 19) + 3;
    constexpr float with_foot = (10 * 19) + 4;

    const WorkbenchGeometry framed{.area = {.width = width, .height = with_foot}, .grid = grid};

    check(framed.foot() == 4, "the foot must be half a column");
    check(framed.cellArea().height == 10, "a workbench with room for the foot must keep every whole row");
    check(WorkbenchGeometry{.area = {.width = width, .height = short_of_foot}, .grid = grid}.cellArea().height == 9, "a workbench short of the foot must give a row to it");

    const WorkbenchGeometry gapless{.area = {.width = width, .height = short_of_foot}, .grid = grid, .layout_metrics = {.gap = 0}};

    check(gapless.foot() == 0 && gapless.cellArea().height == 10, "a workbench without gaps must keep no foot: its panes keep a row");
    const WorkbenchGeometry borderless{.area = {.width = width, .height = short_of_foot}, .grid = grid, .layout_metrics = {.border = 0}};

    check(borderless.foot() == 0 && borderless.cellArea().height == 10, "a workbench of borderless panes must keep no foot");
  }

  const telar::testing::Case case_panes_keep_no_row_under_their_content_beside_gaps{"pane_layout.panes_keep_no_row_under_their_content_beside_gaps", panesKeepNoRowUnderTheirContentBesideGaps};
  const telar::testing::Case case_workbench_keeps_room_at_its_foot_for_framed_panes{"pane_layout.workbench_keeps_room_at_its_foot_for_framed_panes", workbenchKeepsRoomAtItsFootForFramedPanes};
  const telar::testing::Case case_reservations_respect_minimums_and_borderless_content{"attachment_layout.reservations_respect_minimums_and_borderless_content", reservationsRespectMinimumsAndBorderlessContent};
  const telar::testing::Case case_reservations_leave_sibling_geometry_and_split_content_consistent{"attachment_layout.reservations_leave_sibling_geometry_and_split_content_consistent", reservationsLeaveSiblingGeometryAndSplitContentConsistent};

}
