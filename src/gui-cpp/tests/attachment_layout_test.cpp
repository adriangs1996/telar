#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <cstdint>
#include <algorithm>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <exception>
#include <iostream>



import telar.gui.application.sound_playback;
import telar.gui.core.unicode_scalar;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

constexpr std::uint64_t first_pane = 1;
constexpr std::uint64_t second_pane = 2;
constexpr std::uint16_t columns = 80;
constexpr std::uint16_t tall_rows = 24;

void reservationsRespectMinimumsAndBorderlessContent() {
  PaneLayout layout;
  require(layout.add(first_pane, ClientLayoutAxis::horizontal, 0), "the first pane must exist");
  layout.setBottomReservation(PaneBottomReservation{.pane_id = first_pane});
  constexpr auto maximum_test_rows = PaneBottomReservation::shelf_rows + PaneBottomReservation::pane_minimum_rows;
  for (std::uint16_t rows = 0; rows <= maximum_test_rows; ++rows) {
    const auto views = layout.arrange({.width = columns, .height = rows}, {.border = 0});
    require(views.size() == 1, "reservation must preserve the single pane");
    const auto available = rows > PaneBottomReservation::pane_minimum_rows ? rows - PaneBottomReservation::pane_minimum_rows : 0;
    const auto wanted = std::min<unsigned>(PaneBottomReservation::shelf_rows, available);
    const auto reserved = wanted >= PaneBottomReservation::shelf_minimum_rows ? wanted : 0;
    require(views.front().bounds.height == rows - reserved && views.front().content == views.front().bounds, "small borderless panes must preserve their minimum content and use whole cells");
    require(layout.reservedArea().height == reserved, "insufficient shelf height must reserve nothing");
  }

  layout.setBottomReservation(std::nullopt);
  const auto restored = layout.arrange({.width = columns, .height = tall_rows}, {});
  require(restored.front().bounds.height == tall_rows && layout.reservedArea().empty(), "removing the shelf must restore every terminal row");
}

void reservationsLeaveSiblingGeometryAndSplitContentConsistent() {
  PaneLayout layout;
  require(layout.add(first_pane, ClientLayoutAxis::horizontal, 0) && layout.add(second_pane, ClientLayoutAxis::horizontal, first_pane), "the two-pane fixture must exist");
  constexpr CellRectangle host{.width = columns, .height = tall_rows};
  const auto before = layout.arrange(host, {});
  const auto sibling = before.back();
  const auto first = before.front();
  layout.setBottomReservation(PaneBottomReservation{.pane_id = first_pane});
  const auto after = layout.arrange(host, {});
  require(after.back().bounds == sibling.bounds && after.back().content == sibling.content, "another pane's shelf must preserve sibling bounds and content");
  require(after.front().bounds.height == first.bounds.height - PaneBottomReservation::shelf_rows && after.front().content == after.front().bounds.inner(1), "framed panes must recompute their inner terminal after reservation");
  require(layout.reservedArea().y == after.front().bounds.bottom(), "the shelf must begin exactly below the shortened outer pane");
  const auto split = layout.prospectiveSplit(host, ClientLayoutAxis::horizontal, first_pane, {});
  require(split && split->existing_content.height == after.front().content.height && split->added_content.height == after.front().content.height, "prospective horizontal splits must use the same reserved height as the visible terminal");
}

}

int main() try {
  reservationsRespectMinimumsAndBorderlessContent();
  reservationsLeaveSiblingGeometryAndSplitContentConsistent();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
