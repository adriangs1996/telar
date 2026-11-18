#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>

import std;
import telar.testing;
import telar.gui.features.terminal.input;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::terminal::input;

  ChildMouseView view() {
    constexpr float origin_x = 100;
    constexpr float origin_y = 200;
    constexpr float cell_width = 10;
    constexpr float cell_height = 20;
    constexpr std::uint16_t columns = 8;
    constexpr std::uint16_t rows = 4;

    return {.pane_id = 1, .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1}, .surface = {.content = {.x = origin_x, .y = origin_y, .width = cell_width * columns, .height = cell_height * rows}, .cell = {.x = cell_width, .y = cell_height}, .attachment_generation = 2}, .protocol = {.tracking = MouseTracking::button, .sgr = true}, .columns = columns, .rows = rows, .cell_width_px = static_cast<std::uint16_t>(cell_width), .cell_height_px = static_cast<std::uint16_t>(cell_height), .attached = true};
  }

  ChildMouseSample sample(MouseButton button = MouseButton::left) {
    return {.button = button, .position = {.x = view().surface.content.x, .y = view().surface.content.y}};
  }

  void independentButtons() {
    std::array<ChildMouseGesture, static_cast<std::size_t>(MouseButton::none)> gestures;

    for (const auto button : {MouseButton::left, MouseButton::middle, MouseButton::right}) {
      gestures[static_cast<std::size_t>(button)].begin(view(), sample(button));
    }

    auto release = sample();

    release.phase = MousePhase::release;
    check(gestures[0].deliver(view(), release) == ChildMouseReport{.button = 0, .x = 1, .y = 1, .released = true}, "the first release must retain its own button");
    check(!gestures[0].owned() && gestures[1].owned() && gestures[2].owned(), "one release must preserve the other button leases");
    check(gestures[1].cancel(view()) == ChildMouseReport{.button = 1, .x = 1, .y = 1, .released = true}, "cancellation must release the middle button independently");
    check(gestures[2].cancel(view()) == ChildMouseReport{.button = 2, .x = 1, .y = 1, .released = true}, "cancellation must release the right button independently");
    check(!gestures[1].cancel(view()) && !gestures[2].cancel(view()), "completed cancellation must not produce duplicate releases");
  }

  void identityAndModes() {
    enum class IdentityField : std::uint8_t {
      pane,
      attachment,
      tab,
      connection,
    };

    for (const auto field : {IdentityField::pane, IdentityField::attachment, IdentityField::tab, IdentityField::connection}) {
      auto changed = view();

      switch (field) {
      case IdentityField::pane:
        ++changed.pane_id;
        break;
      case IdentityField::attachment:
        ++changed.surface.attachment_generation;
        break;
      case IdentityField::tab:
        ++changed.location.tab_id;
        break;
      case IdentityField::connection:
        changed.attached = false;
        break;
      }

      ChildMouseGesture gesture;

      gesture.begin(view(), sample());
      check(!gesture.cancel(changed) && !gesture.owned(), "a stale attachment, pane or tab must consume cancellation without reporting to a replacement");
    }

    for (const auto tracking : {MouseTracking::none, MouseTracking::x10, MouseTracking::normal, MouseTracking::button, MouseTracking::any}) {
      for (const bool sgr : {false, true}) {
        auto current = view();

        current.protocol = {.tracking = tracking, .sgr = sgr};
        ChildMouseGesture gesture;

        gesture.begin(current, sample());
        const auto released = gesture.cancel(current);
        const auto retainable = sgr && tracking != MouseTracking::none && tracking != MouseTracking::x10;

        check(released.hasValue() == retainable && !gesture.owned(), "only matching SGR modes may retain and finish a press");
      }
    }
  }

  void retainedGeometry() {
    ChildMouseGesture gesture;

    gesture.begin(view(), sample(MouseButton::middle));
    auto hidden = view();

    hidden.visible = false;
    hidden.surface.content.x += hidden.surface.content.width;
    auto drag = sample(MouseButton::middle);

    drag.phase = MousePhase::drag;
    drag.position.x = view().surface.content.right();
    drag.position.y = view().surface.content.bottom();
    const auto expected = ChildMouseReport{.button = static_cast<unsigned>(MouseButton::middle) | ChildMouseProjection::motion, .x = view().columns, .y = view().rows};

    check(gesture.deliver(hidden, drag) == expected, "a hidden pane must preserve and clamp its last displayed content rectangle");
    hidden.visible = true;
    const auto moved = gesture.deliver(hidden, drag);

    check(moved && moved->x == 1 && moved->y == view().rows, "visible geometry changes must update the retained projection");
    auto normal = hidden;

    normal.protocol.tracking = MouseTracking::normal;
    check(!gesture.deliver(normal, drag) && gesture.owned(), "normal tracking must suppress motion without releasing ownership");
    check(gesture.cancel(normal).hasValue(), "a mode-suppressed drag must still retain its final release");
  }

  void pixelsAndInvalidGeometry() {
    auto current = view();

    current.protocol.pixels = true;
    current.surface.scale = 2;
    current.cell_width_px *= 2;
    current.cell_height_px *= 2;
    auto point = sample();

    point.position.x += current.surface.cell.x / 2;
    point.position.y += current.surface.cell.y / 2;
    const auto center = ChildMouseProjection::project(current, point);

    check(center && center->x == (current.cell_width_px / 2) + 1U && center->y == (current.cell_height_px / 2) + 1U, "pixel reporting must preserve the exact scaled physical position");
    point.position = {.x = std::numeric_limits<float>::max(), .y = -std::numeric_limits<float>::max()};
    const auto clipped = ChildMouseProjection::project(current, point);

    check(clipped && clipped->x == static_cast<unsigned>(current.columns) * current.cell_width_px && clipped->y == 1, "retained coordinates must clamp before integer conversion");
    point.position.x = std::numeric_limits<float>::quiet_NaN();
    check(!ChildMouseProjection::project(current, point), "non-finite input must not reach integer conversion");
    current.surface.cell.y = 0;
    check(!ChildMouseProjection::project(current, sample()), "invalid cell geometry must not authorize a report");
  }

  const telar::testing::Case case_independent_buttons{"child_mouse.independent_buttons", independentButtons};
  const telar::testing::Case case_identity_and_modes{"child_mouse.identity_and_modes", identityAndModes};
  const telar::testing::Case case_retained_geometry{"child_mouse.retained_geometry", retainedGeometry};
  const telar::testing::Case case_pixels_and_invalid_geometry{"child_mouse.pixels_and_invalid_geometry", pixelsAndInvalidGeometry};

}
