#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string>
#include <string_view>

import telar.testing;
import telar.gui.application;
import telar.gui.features.notifications;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;

  constexpr std::uint64_t frame_interval_ns = 16'000'000;
  constexpr std::uint64_t midpoint_ns = NotificationItem::transition_duration_ns / 2;
  constexpr float midpoint_opacity = 0.5F;
  constexpr std::string_view invalid_text = "invalid notification text";

  void ownsAndBoundsEveryPayload() {
    NotificationCenter center;
    std::string title = "Original title";
    std::string message = "Original message";
    const auto id = center.push(0, {.title = title, .message = message, .link = "https://auth.example/login"});

    title.assign("Replaced title");
    message.assign("Replaced message");
    const auto* item = center.find(id);

    check(item != nullptr && item->title.view() == "Original title" && item->message.view() == "Original message", "published text must survive caller mutation");
    check(item->clickable() && item->linkHost() == "auth.example", "a link must expose the actual validated authority");

    const auto long_title = std::string(max_notification_title_bytes - 1, 'a') + "é";
    const std::string long_link(max_notification_link_bytes + 1, 'x');
    const auto bounded = center.push(0, {.title = long_title, .message = "\xc3\x28", .link = long_link});
    const auto* clipped = center.find(bounded);

    check(clipped != nullptr && clipped->title.view().size() == max_notification_title_bytes - 1, "a bounded title must retain complete UTF-8 scalars");
    check(clipped->message.view() == invalid_text, "invalid local text must use the original bounded fallback");
    check(clipped->link.view().empty() && !clipped->clickable(), "an oversized link must be dropped whole");
  }

  void expiresByElapsedTimeAndSleepsWhenStable() {
    NotificationCenter center;
    const auto id = center.push(0, {.title = "Finished", .message = {}, .link = {}});

    check(center.nextDeadline(0, frame_interval_ns) == frame_interval_ns, "an entering notice must follow the display cadence");
    check(center.find(id)->opacity(midpoint_ns) == midpoint_opacity, "rendering must sample the original smoothstep transition without mutating state");
    check(center.find(id)->transition_position_ns == 0, "a rendering sample must remain disposable");
    check(center.advance(NotificationItem::transition_duration_ns), "the entering transition must reach its visible phase");
    const auto expiry = NotificationItem::transition_duration_ns + NotificationInput::default_duration_ns;

    check(center.nextDeadline(NotificationItem::transition_duration_ns, frame_interval_ns) == expiry, "stable notices must sleep until exact expiry");
    check(center.advance(expiry + NotificationItem::transition_duration_ns) && center.items().empty(), "late frames must remove an expired notice without stretching either transition");
    check(!center.nextDeadline(expiry, frame_interval_ns), "an empty center must request no work");
  }

  void duplicateRefreshDoesNotReorderAndExitingItemsDoNotRevive() {
    NotificationCenter center;
    const NotificationInput first{.title = "First", .message = {}, .link = {}};
    const auto original = center.push(0, first);
    const auto second = center.push(0, {.title = "Second", .message = {}, .link = {}});

    check(center.push(midpoint_ns, first) == original && center.items().front().id == second, "an equivalent notice must refresh its identity and preserve stack order");
    check(center.find(original)->expires_at_ns == midpoint_ns + NotificationItem::transition_duration_ns + first.duration_ns, "refresh during entry must retain the original entry allowance");
    check(center.advance(NotificationItem::transition_duration_ns), "both notices must become visible");
    check(center.push(NotificationItem::transition_duration_ns, first) == original, "a visible duplicate must preserve identity");
    check(center.find(original)->expires_at_ns == NotificationItem::transition_duration_ns + first.duration_ns, "visible refresh must add only the requested duration");
    check(center.dismiss(original, NotificationItem::transition_duration_ns), "dismissal must start one exit transition");
    check(!center.dismiss(original, NotificationItem::transition_duration_ns), "an exiting notice must ignore repeated dismissal");
    check(center.push(NotificationItem::transition_duration_ns, first) != original, "a new notice must not revive an exiting identity");
  }

  void activationIsOnceAndCapacityEvictsTheOldest() {
    NotificationCenter center;
    const NotificationInput input{.target = {.kind = NotificationTarget::Kind::pane, .id = 1}, .title = "Agent needs input", .message = {}, .link = {}};
    const auto oldest = center.push(0, input);
    const auto target = center.activate(oldest, midpoint_ns);

    check(target && target->kind == NotificationTarget::Kind::pane && target->id == input.target.id, "activation must return the semantic target");
    check(!center.activate(oldest, midpoint_ns), "one identity must activate at most once");
    check(center.find(oldest)->transition_position_ns == midpoint_ns, "dismissal during entry must exit from the currently sampled position");
    for (std::uint64_t index = 0; index < NotificationCenter::capacity; ++index) {
      auto next = input;

      next.target.id = index + 2;
      center.push(midpoint_ns, next);
    }

    check(center.items().size() == NotificationCenter::capacity && center.find(oldest) == nullptr, "a full center must evict its oldest retained notice");
    check(!center.activate(oldest, midpoint_ns) && !center.dismiss(oldest, midpoint_ns), "evicted identities must remain stale no-ops");
  }

  void identitiesAndDeadlinesSaturateWithoutInvalidZeroIds() {
    constexpr auto last = std::numeric_limits<std::uint64_t>::max();
    NotificationCenter center{last};

    check(center.push(last, {.title = "Last", .message = {}, .link = {}, .duration_ns = last}) == NotificationId{last}, "the final nonzero identity must remain usable");
    check(center.items().front().expires_at_ns == last && center.nextDeadline(last, frame_interval_ns) == last, "absolute deadlines must saturate instead of wrapping");
    check(center.push(last, {.title = "Wrapped", .message = {}, .link = {}}) == NotificationId{1}, "identity rollover must skip the invalid zero identity");
  }

  const telar::testing::Case case_owns_and_bounds_every_payload{"notification_center.owns_and_bounds_every_payload", ownsAndBoundsEveryPayload};
  const telar::testing::Case case_expires_by_elapsed_time_and_sleeps_when_stable{"notification_center.expires_by_elapsed_time_and_sleeps_when_stable", expiresByElapsedTimeAndSleepsWhenStable};
  const telar::testing::Case case_duplicate_refresh_does_not_reorder_and_exiting_items_do_not_revive{"notification_center.duplicate_refresh_does_not_reorder_and_exiting_items_do_not_revive", duplicateRefreshDoesNotReorderAndExitingItemsDoNotRevive};
  const telar::testing::Case case_activation_is_once_and_capacity_evicts_the_oldest{"notification_center.activation_is_once_and_capacity_evicts_the_oldest", activationIsOnceAndCapacityEvictsTheOldest};
  const telar::testing::Case case_identities_and_deadlines_saturate_without_invalid_zero_ids{"notification_center.identities_and_deadlines_saturate_without_invalid_zero_ids", identitiesAndDeadlinesSaturateWithoutInvalidZeroIds};

}
