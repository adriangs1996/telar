#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "assertions.hpp"
#include "core/geometry.hpp"
#include "presentation/notification_geometry.hpp"
#include "presentation/notification_stack.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <exception>
#include <iostream>

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

constexpr std::uint64_t second = 1'000'000'000;
constexpr Rect host{.x = 100, .y = 50, .width = 800, .height = 500};
constexpr float card_height = 100;
constexpr std::uint64_t visible_pane_id = 42;

auto prepare(NotificationStack &stack, const NotificationCenter &center, std::uint64_t now_ns) {
  return stack.prepare({.items = center.items(), .host = host, .now_ns = now_ns}, [](const NotificationItem &) {
    return false;
  },
                       [](const NotificationItem &, float) {
                         return card_height;
                       });
}

void cardsUseBoundedPainterOrderAndRetargetFromTheirCurrentPosition() {
  NotificationCenter center;
  const auto oldest = center.push(second, {.title = "First", .message = {}, .link = {}});
  NotificationStack stack;
  const auto initial = prepare(stack, center, 2 * second);
  require(initial.count == 1 && initial.items().front().id == oldest, "a mature notice must produce one visible card");
  require(initial.items().front().bounds == Rect{.x = host.right() - NotificationMetrics::margin - NotificationMetrics::preferred_width, .y = host.y + NotificationMetrics::margin, .width = NotificationMetrics::preferred_width, .height = card_height}, "card geometry must anchor to the complete host grid");

  const auto newest = center.push(2 * second, {.title = "Second", .message = {}, .link = {}});
  const auto arrival = prepare(stack, center, 2 * second);
  require(arrival.count == 1 && arrival.items().front().id == oldest, "an opacity-zero entering card must reserve its slot without painting");
  const auto middle = prepare(stack, center, (2 * second) + (NotificationStack::motion_duration_ns / 2));
  require(middle.count == NotificationStack::maximum_visible && middle.items().front().id == oldest && middle.items().back().id == newest, "newest cards must paint last during stack motion");
  const auto half_shift = (card_height + NotificationMetrics::stack_gap) / 2;
  require(middle.items().front().bounds.y == host.y + NotificationMetrics::margin + half_shift, "stack movement must use the original smoothstep at the halfway point");
  require(stack.nextDeadline((2 * second) + (NotificationStack::motion_duration_ns / 2), second).has_value(), "moving cards must request another frame");
  static_cast<void>(prepare(stack, center, 3 * second));
  require(!stack.nextDeadline(3 * second, second), "settled stack positions must not poll");
}

void suppressedTargetsAndSmallHostsDoNotPaintOrConsumeCapacity() {
  NotificationCenter center;
  center.push(second, {.title = "First", .message = {}, .link = {}});
  center.push(second, {.target = {.kind = NotificationTarget::Kind::pane, .id = visible_pane_id}, .title = "Visible pane", .message = {}, .link = {}});
  NotificationStack stack;
  const auto cards = stack.prepare({.items = center.items(), .host = host, .now_ns = 2 * second}, [](const NotificationItem &item) {
    return item.target.kind == NotificationTarget::Kind::pane;
  },
                                   [](const NotificationItem &, float) {
                                     return card_height;
                                   });
  require(cards.count == 1 && cards.items().front().index == 1 && center.items().size() == 2, "visible targets must be suppressed only in presentation");
  const auto narrow = stack.prepare({.items = center.items(), .host = {.width = NotificationMetrics::minimum_width, .height = host.height}, .now_ns = 2 * second}, [](const NotificationItem &) {
    return false;
  },
                                    [](const NotificationItem &, float) {
                                      return card_height;
                                    });
  require(narrow.count == 0 && !stack.nextDeadline(2 * second, second), "an undersized host must clear stack motion and card hits");
}

}

int main() try {
  cardsUseBoundedPainterOrderAndRetargetFromTheirCurrentPosition();
  suppressedTargetsAndSmallHostsDoNotPaintOrConsumeCapacity();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
