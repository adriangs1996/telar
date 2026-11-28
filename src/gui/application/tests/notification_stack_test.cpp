#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

import telar.testing;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.features.notifications;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;

  constexpr std::uint64_t second = 1'000'000'000;
  constexpr Rect host{.x = 100, .y = 50, .width = 800, .height = 500};
  constexpr float card_height = 100;
  constexpr std::uint64_t visible_pane_id = 42;

  auto prepare(NotificationStack& stack, const NotificationCenter& center, std::uint64_t now_ns) {
    return stack.prepare({.items = center.items(), .host = host, .now_ns = now_ns}, [](const NotificationItem&) {
      return false;
    },
        [](const NotificationItem&, float) {
          return card_height;
        });
  }

  void cardsUseBoundedPainterOrderAndRetargetFromTheirCurrentPosition() {
    NotificationCenter center;
    const auto oldest = center.push(second, {.title = "First", .message = {}, .link = {}});
    NotificationStack stack;
    const auto initial = prepare(stack, center, 2 * second);

    check(initial.count == 1 && initial.items().front().id == oldest, "a mature notice must produce one visible card");
    check(initial.items().front().bounds == Rect{.x = host.right() - NotificationMetrics::margin - NotificationMetrics::preferred_width, .y = host.y + NotificationMetrics::margin, .width = NotificationMetrics::preferred_width, .height = card_height}, "card geometry must anchor to the complete host grid");

    const auto newest = center.push(2 * second, {.title = "Second", .message = {}, .link = {}});
    const auto arrival = prepare(stack, center, 2 * second);

    check(arrival.count == 1 && arrival.items().front().id == oldest, "an opacity-zero entering card must reserve its slot without painting");
    const auto middle = prepare(stack, center, (2 * second) + (NotificationStack::motion_duration_ns / 2));

    check(middle.count == NotificationStack::maximum_visible && middle.items().front().id == oldest && middle.items().back().id == newest, "newest cards must paint last during stack motion");
    const auto half_shift = (card_height + NotificationMetrics::stack_gap) / 2;

    check(middle.items().front().bounds.y == host.y + NotificationMetrics::margin + half_shift, "stack movement must use the original smoothstep at the halfway point");
    check(stack.nextDeadline((2 * second) + (NotificationStack::motion_duration_ns / 2), second).hasValue(), "moving cards must request another frame");
    static_cast<void>(prepare(stack, center, 3 * second));
    check(!stack.nextDeadline(3 * second, second), "settled stack positions must not poll");
  }

  void suppressedTargetsAndSmallHostsDoNotPaintOrConsumeCapacity() {
    NotificationCenter center;

    center.push(second, {.title = "First", .message = {}, .link = {}});
    center.push(second, {.target = {.kind = NotificationTarget::Kind::pane, .id = visible_pane_id}, .title = "Visible pane", .message = {}, .link = {}});
    NotificationStack stack;
    const auto cards = stack.prepare({.items = center.items(), .host = host, .now_ns = 2 * second}, [](const NotificationItem& item) {
      return item.target.kind == NotificationTarget::Kind::pane;
    },
        [](const NotificationItem&, float) {
          return card_height;
        });

    check(cards.count == 1 && cards.items().front().index == 1 && center.items().size() == 2, "visible targets must be suppressed only in presentation");
    const auto narrow = stack.prepare({.items = center.items(), .host = {.width = NotificationMetrics::minimum_width, .height = host.height}, .now_ns = 2 * second}, [](const NotificationItem&) {
      return false;
    },
        [](const NotificationItem&, float) {
          return card_height;
        });

    check(narrow.count == 0 && !stack.nextDeadline(2 * second, second), "an undersized host must clear stack motion and card hits");
  }

  const telar::testing::Case case_cards_use_bounded_painter_order_and_retarget_from_their_current_position{"notification_stack.cards_use_bounded_painter_order_and_retarget_from_their_current_position", cardsUseBoundedPainterOrderAndRetargetFromTheirCurrentPosition};
  const telar::testing::Case case_suppressed_targets_and_small_hosts_do_not_paint_or_consume_capacity{"notification_stack.suppressed_targets_and_small_hosts_do_not_paint_or_consume_capacity", suppressedTargetsAndSmallHostsDoNotPaintOrConsumeCapacity};

}
