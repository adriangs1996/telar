#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <limits>
#include <optional>
#include <array>
#include "../terminal/cell_position.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <utility>
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "../terminal/screen.hpp"
#include <span>
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>

#include "terminal/screen.hpp"


import telar.gui.core.metrics;
import telar.gui.core.unicode_scalar;
import telar.gui.links.link_hover;
import telar.gui.links.path_expansion;
import telar.gui.links.cell_links;

namespace {

using namespace telar;
using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

LinkHit hit(std::string_view text = "https://first.test") {
  const auto target = LinkTarget::fromUri(text);
  if (!target) {
    throw std::runtime_error{"The link fixture must classify as a URI"};
  }

  constexpr std::uint16_t end_column = 20;
  constexpr float content_columns = 80;
  constexpr float content_rows = 24;

  return {
      .pane_id = 1,
      .generation = 2,
      .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1},
      .content = {.width = content_columns, .height = content_rows},
      .scroll_offset = 0,
      .area = {.y = 1, .width = end_column, .height = 1},
      .match = {.target = *target, .start = {.y = 1}, .end = {.x = end_column, .y = 1}},
  };
}

TerminalSurface surface() {
  return {.content = hit().content, .cell = {.x = 1, .y = 1}, .attachment_generation = 2};
}

void gestureContexts() {
  constexpr ViewVersion original;
  constexpr auto fields = std::to_array<std::uint64_t ViewVersion::*>({&ViewVersion::workspace, &ViewVersion::active_tab, &ViewVersion::tabs, &ViewVersion::panes, &ViewVersion::host, &ViewVersion::configuration, &ViewVersion::viewport});
  LinkGesture gesture;
  for (const auto field : fields) {
    gesture.begin(hit(), original);
    auto changed = original;
    ++(changed.*field);
    gesture.validate(hit(), changed);
    require(!gesture.finish(hit(), original), "a restored context must not revive an intervening cancellation");
  }

  gesture.begin(hit(), original);
  require(gesture.finish(hit(), original).has_value() && !gesture.active(), "an unchanged press and release must open exactly once");
  require(!gesture.finish(hit(), original), "a second release must not reopen a completed click");
  gesture.begin(hit(), original);
  gesture.cancel();
  require(!gesture.finish(hit(), original), "a drag or lost grab must not open a target");
}

void completeHitIdentity() {
  enum class Field : std::uint8_t {
    pane,
    attachment,
    workspace,
    tab,
    content,
    viewport,
    area,
    start,
    end,
    metadata,
    destination,
  };
  for (const auto field : {Field::pane, Field::attachment, Field::workspace, Field::tab, Field::content, Field::viewport, Field::area, Field::start, Field::end, Field::metadata, Field::destination}) {
    auto changed = hit();
    switch (field) {
    case Field::pane:
      ++changed.pane_id;
      break;
    case Field::attachment:
      ++changed.generation;
      break;
    case Field::workspace:
      ++changed.location.workspace.id;
      break;
    case Field::tab:
      ++changed.location.tab_id;
      break;
    case Field::content:
      ++changed.content.x;
      break;
    case Field::viewport:
      ++changed.scroll_offset;
      break;
    case Field::area:
      ++changed.area.y;
      break;
    case Field::start:
      ++changed.match.start.x;
      break;
    case Field::end:
      ++changed.match.end.y;
      break;
    case Field::metadata:
      changed.match.metadata_index = 0;
      break;
    case Field::destination:
      changed.match.target = hit("https://different.test").match.target;
      break;
    }

    LinkGesture gesture;
    gesture.begin(hit(), {});
    gesture.validate(changed, {});
    require(!gesture.finish(hit(), {}), "every part of a link hit must retain its identity throughout the click");
  }
}

void preparedPresentation() {
  LinkHover hover;
  static_cast<void>(hover.assign(hit(), surface(), true));
  require(!hover.openable(surface()), "unpresented geometry must not authorize a link");
  const auto prepared = hover.prepare(surface(), {});
  static_cast<void>(hover.assign(hit("https://second.test"), surface(), false));
  hover.present(prepared);
  require(!hover.openable(surface()), "a frame must publish its captured target rather than a later pointer resolution");
  const auto next = hover.prepare(surface(), {});
  hover.present(next, false);
  require(!hover.openable(surface()), "a discarded frame must not authorize its target");
  hover.present(next);
  require(hover.openable(surface()), "a delivered matching target must become openable");

  static_cast<void>(hover.assign(hit("https://third.test"), surface(), true));
  require(hover.openable(surface()), "a new hover over an already displayed terminal frame needs no extra frame");
  auto moved = surface();
  ++moved.content.x;
  require(!hover.openable(moved), "pointer input must wait for matching displayed geometry");
}

void deliveredCover() {
  LinkHover hover;
  static_cast<void>(hover.assign(hit(), surface(), false));
  const Rect cover{.x = 2, .y = 3, .width = 10, .height = 2};
  hover.present(hover.prepare(surface(), cover));
  require(hover.covers({.x = 3, .y = 4}) && !hover.covers({.x = cover.x + cover.width, .y = 4}), "tooltip coverage must use its delivered rectangle with an exclusive right edge");
  hover.clear();
  require(hover.covers({.x = 3, .y = 4}) && !hover.current(), "hiding a tooltip must preserve its input coverage until the replacement frame is delivered");
  hover.present(hover.prepare(surface(), {}));
  require(!hover.covers({.x = 3, .y = 4}), "a delivered clearing frame must release the covered cells");
}

void pointerPolicy() {
  require(LinkPointerPolicy::hover(LinkScheme::https, {}) == LinkAffordance::link, "plain URIs must expose link affordances");
  require(LinkPointerPolicy::hover(LinkScheme::path, {}) == LinkAffordance::text && LinkPointerPolicy::hover(LinkScheme::path, {.native = true}) == LinkAffordance::link, "guessed paths must require the native link modifier");
  require(LinkPointerPolicy::hover(LinkScheme::https, {.alt = true}) == LinkAffordance::pointer && LinkPointerPolicy::hover(LinkScheme::path, {.alt = true}) == LinkAffordance::pointer, "Alt must preserve the pointer shape while removing the link target");
  require(LinkPointerPolicy::press({.has_link = true, .openable = true}) == LinkPress::arm_shared, "a plain URI click must share its press with selection");
  require(LinkPointerPolicy::press({.modifiers = {.native = true}, .has_link = true, .openable = true}) == LinkPress::arm_exclusive, "the native modifier must retain an openable link press");
  require(LinkPointerPolicy::press({.modifiers = {.native = true}, .has_link = true}) == LinkPress::discard, "an unpresented modified link must swallow its complete click");
  require(LinkPointerPolicy::press({.modifiers = {.native = true}, .child_tracking = true, .has_link = true, .openable = true}) == LinkPress::passthrough, "child mouse tracking must retain its ordinary modified presses");
  require(LinkPointerPolicy::press({.modifiers = {.native = true, .shift = true}, .child_tracking = true, .has_link = true, .openable = true}) == LinkPress::arm_exclusive, "Shift must allow a link press to override child mouse tracking");
  require(LinkPointerPolicy::press({.button = LinkButton::right, .modifiers = {.alt = true}, .child_tracking = true, .has_link = true, .frame_presented = true}) == LinkPress::copy, "right click must copy a displayed target independently of child mouse tracking and Alt");
  require(LinkPointerPolicy::press({.button = LinkButton::right, .has_link = true}) == LinkPress::discard, "right click must swallow an unpresented target without copying it");
}

void regionTraversal() {
  constexpr std::uint16_t columns = 8;
  constexpr std::uint16_t rows = 3;
  constexpr std::uint32_t offset = 10;
  const std::array<CellValue, static_cast<std::size_t>(columns) * rows> cells{};
  const std::array<Byte, rows> flags{static_cast<Byte>(RowFlag::wide_padding), 0, 0};
  const LinkGrid grid{.cells = cells, .columns = columns, .rows = rows, .scroll = {.total_rows = offset + rows, .offset = offset}, .row_flags = flags};
  auto match = hit().match;
  match.start = {.x = 2, .y = offset};
  constexpr std::uint16_t last_column = 5;
  match.end = {.x = last_column, .y = offset + 2};
  LinkRegions plain{match, grid, {}};
  require(plain.next() == LinkRegion{.x = 2, .y = 0, .width = last_column}, "plain underlines must skip wide-glyph padding");
  require(plain.next() == LinkRegion{.x = 0, .y = 1, .width = columns}, "plain underlines must continue across logical rows");
  require(plain.next() == LinkRegion{.x = 0, .y = 2, .width = last_column} && !plain.next(), "plain underlines must stop at the exclusive link end");

  match.metadata_index = 1;
  const std::array runs{MetadataRun{.start = 1, .len = 2, .link_index = 1}, MetadataRun{.start = last_column, .len = 2, .link_index = 0}, MetadataRun{.start = columns + 1, .len = 3, .link_index = 1}};
  LinkRegions osc8{match, grid, runs};
  require(osc8.next() == LinkRegion{.x = 1, .y = 0, .width = 2}, "OSC 8 underlines must use metadata run bounds");
  require(osc8.next() == LinkRegion{.x = 1, .y = 1, .width = 3} && !osc8.next(), "every run of an OSC 8 identity must be underlined without including neighboring identities");
  LinkRegions clipped{match, grid, runs, {.columns = 2, .rows = 1}};
  require(clipped.next() == LinkRegion{.x = 1, .y = 0, .width = 1} && !clipped.next(), "the iterator must clip to the visible pane before producing render geometry");
}

}

int main() {
  try {
    gestureContexts();
    completeHitIdentity();
    preparedPresentation();
    deliveredCover();
    pointerPolicy();
    regionTraversal();
    std::puts("gui-link-interaction: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-link-interaction: " << error.what() << '\n';

    return 1;
  }
}
