#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.gui.foundation.terminal;
import telar.gui.foundation.core;
import telar.gui.features.terminal.links;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::terminal::links;

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
    constexpr auto fields = ds::Array<std::uint64_t ViewVersion::*, 7>{&ViewVersion::workspace, &ViewVersion::active_tab, &ViewVersion::tabs, &ViewVersion::panes, &ViewVersion::host, &ViewVersion::configuration, &ViewVersion::viewport};
    LinkGesture gesture;

    for (const auto field : fields) {
      gesture.begin(hit(), original);
      auto changed = original;

      ++(changed.*field);
      gesture.validate(hit(), changed);
      check(!gesture.finish(hit(), original), "a restored context must not revive an intervening cancellation");
    }

    gesture.begin(hit(), original);
    check(gesture.finish(hit(), original).hasValue() && !gesture.active(), "an unchanged press and release must open exactly once");
    check(!gesture.finish(hit(), original), "a second release must not reopen a completed click");
    gesture.begin(hit(), original);
    gesture.cancel();
    check(!gesture.finish(hit(), original), "a drag or lost grab must not open a target");
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
      check(!gesture.finish(hit(), {}), "every part of a link hit must retain its identity throughout the click");
    }
  }

  void preparedPresentation() {
    LinkHover hover;

    static_cast<void>(hover.assign(hit(), surface(), true));
    check(!hover.openable(surface()), "unpresented geometry must not authorize a link");
    const auto prepared = hover.prepare(surface(), {});

    static_cast<void>(hover.assign(hit("https://second.test"), surface(), false));
    hover.present(prepared);
    check(!hover.openable(surface()), "a frame must publish its captured target rather than a later pointer resolution");
    const auto next = hover.prepare(surface(), {});

    hover.present(next, false);
    check(!hover.openable(surface()), "a discarded frame must not authorize its target");
    hover.present(next);
    check(hover.openable(surface()), "a delivered matching target must become openable");

    static_cast<void>(hover.assign(hit("https://third.test"), surface(), true));
    check(hover.openable(surface()), "a new hover over an already displayed terminal frame needs no extra frame");
    auto moved = surface();

    ++moved.content.x;
    check(!hover.openable(moved), "pointer input must wait for matching displayed geometry");
  }

  void deliveredCover() {
    LinkHover hover;

    static_cast<void>(hover.assign(hit(), surface(), false));
    const Rect cover{.x = 2, .y = 3, .width = 10, .height = 2};

    hover.present(hover.prepare(surface(), cover));
    check(hover.covers({.x = 3, .y = 4}) && !hover.covers({.x = cover.x + cover.width, .y = 4}), "tooltip coverage must use its delivered rectangle with an exclusive right edge");
    hover.clear();
    check(hover.covers({.x = 3, .y = 4}) && !hover.current(), "hiding a tooltip must preserve its input coverage until the replacement frame is delivered");
    hover.present(hover.prepare(surface(), {}));
    check(!hover.covers({.x = 3, .y = 4}), "a delivered clearing frame must release the covered cells");
  }

  void pointerPolicy() {
    check(LinkPointerPolicy::hover(LinkScheme::https, {}) == LinkAffordance::link, "plain URIs must expose link affordances");
    check(LinkPointerPolicy::hover(LinkScheme::path, {}) == LinkAffordance::text && LinkPointerPolicy::hover(LinkScheme::path, {.native = true}) == LinkAffordance::link, "guessed paths must require the native link modifier");
    check(LinkPointerPolicy::hover(LinkScheme::https, {.alt = true}) == LinkAffordance::pointer && LinkPointerPolicy::hover(LinkScheme::path, {.alt = true}) == LinkAffordance::pointer, "Alt must preserve the pointer shape while removing the link target");
    check(LinkPointerPolicy::press({.has_link = true, .openable = true}) == LinkPress::arm_shared, "a plain URI click must share its press with selection");
    check(LinkPointerPolicy::press({.modifiers = {.native = true}, .has_link = true, .openable = true}) == LinkPress::arm_exclusive, "the native modifier must retain an openable link press");
    check(LinkPointerPolicy::press({.modifiers = {.native = true}, .has_link = true}) == LinkPress::discard, "an unpresented modified link must swallow its complete click");
    check(LinkPointerPolicy::press({.modifiers = {.native = true}, .child_tracking = true, .has_link = true, .openable = true}) == LinkPress::passthrough, "child mouse tracking must retain its ordinary modified presses");
    check(LinkPointerPolicy::press({.modifiers = {.native = true, .shift = true}, .child_tracking = true, .has_link = true, .openable = true}) == LinkPress::arm_exclusive, "Shift must allow a link press to override child mouse tracking");
    check(LinkPointerPolicy::press({.button = LinkButton::right, .modifiers = {.alt = true}, .child_tracking = true, .has_link = true, .frame_presented = true}) == LinkPress::copy, "right click must copy a displayed target independently of child mouse tracking and Alt");
    check(LinkPointerPolicy::press({.button = LinkButton::right, .has_link = true}) == LinkPress::discard, "right click must swallow an unpresented target without copying it");
  }

  void regionTraversal() {
    constexpr std::uint16_t columns = 8;
    constexpr std::uint16_t rows = 3;
    constexpr std::uint32_t offset = 10;
    const ds::Array<CellValue, static_cast<std::size_t>(columns) * rows> cells{};
    const ds::Array<Byte, rows> flags{static_cast<Byte>(RowFlag::wide_padding), 0, 0};
    const LinkGrid grid{.cells = cells, .columns = columns, .rows = rows, .scroll = {.total_rows = offset + rows, .offset = offset}, .row_flags = flags};
    auto match = hit().match;

    match.start = {.x = 2, .y = offset};
    constexpr std::uint16_t last_column = 5;

    match.end = {.x = last_column, .y = offset + 2};
    LinkRegions plain{match, grid, {}};

    check(plain.next() == LinkRegion{.x = 2, .y = 0, .width = last_column}, "plain underlines must skip wide-glyph padding");
    check(plain.next() == LinkRegion{.x = 0, .y = 1, .width = columns}, "plain underlines must continue across logical rows");
    check(plain.next() == LinkRegion{.x = 0, .y = 2, .width = last_column} && !plain.next(), "plain underlines must stop at the exclusive link end");

    match.metadata_index = 1;
    const ds::Array runs{MetadataRun{.start = 1, .len = 2, .link_index = 1}, MetadataRun{.start = last_column, .len = 2, .link_index = 0}, MetadataRun{.start = columns + 1, .len = 3, .link_index = 1}};
    LinkRegions osc8{match, grid, runs};

    check(osc8.next() == LinkRegion{.x = 1, .y = 0, .width = 2}, "OSC 8 underlines must use metadata run bounds");
    check(osc8.next() == LinkRegion{.x = 1, .y = 1, .width = 3} && !osc8.next(), "every run of an OSC 8 identity must be underlined without including neighboring identities");
    LinkRegions clipped{match, grid, runs, {.columns = 2, .rows = 1}};

    check(clipped.next() == LinkRegion{.x = 1, .y = 0, .width = 1} && !clipped.next(), "the iterator must clip to the visible pane before producing render geometry");
  }

  const telar::testing::Case case_gesture_contexts{"link_interaction.gesture_contexts", gestureContexts};
  const telar::testing::Case case_complete_hit_identity{"link_interaction.complete_hit_identity", completeHitIdentity};
  const telar::testing::Case case_prepared_presentation{"link_interaction.prepared_presentation", preparedPresentation};
  const telar::testing::Case case_delivered_cover{"link_interaction.delivered_cover", deliveredCover};
  const telar::testing::Case case_pointer_policy{"link_interaction.pointer_policy", pointerPolicy};
  const telar::testing::Case case_region_traversal{"link_interaction.region_traversal", regionTraversal};

}
