#include "agent_fixture.hpp"
#include "application/notification_item.hpp"
#include "application/session.hpp"
#include "assertions.hpp"
#include "core/memory.hpp"
#include "session_fixture.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstdint>
#include <exception>
#include <iostream>
#include <string>

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::agentSnapshotEntry;
using telar::gui::test::deliver;
using telar::gui::test::openFirstPane;
using telar::gui::test::require;
using telar::gui::test::Transport;

struct Clock {
  static inline std::uint64_t now_ns = 0;

  static std::uint64_t nowNanoseconds() noexcept {
    return now_ns;
  }
};

using Client = Session<SystemAllocator, Transport, Clock>;
constexpr std::uint64_t second = 1'000'000'000;

void wireMessagesOwnTextAndRetainStructuredActions() {
  SystemAllocator memory;
  Transport transport;
  Client client{memory, transport};
  Clock::now_ns = second;
  std::string title = "Review required";
  std::string body = "The build needs a decision";
  std::string link = "https://example.com/build";
  Notification message;
  message.level = NotificationLevel::warning;
  message.duration_ms = min_notification_duration_ms;
  message.target = {.kind = NotificationTarget::Kind::tab, .id = 2};
  message.title = title;
  message.message = body;
  message.link = link;
  require(deliver(client, message) == Change::notification, "a wire notification must publish a dedicated view change");
  title.assign("modified");
  body.assign("modified");
  link.assign("https://other.example");
  const auto &notice = client.notifications().items().front();
  require(notice.title.view() == "Review required" && notice.message.view() == "The build needs a decision" && notice.link.view() == "https://example.com/build", "notification text must outlive wire decoding and caller mutations");
  require(notice.level == NotificationLevel::warning && notice.target.kind == NotificationTarget::Kind::tab && notice.target.id == 2, "wire metadata must remain structured for rendering and activation");
  require(notice.expires_at_ns == second + NotificationItem::transition_duration_ns + (min_notification_duration_ms * NotificationInput::nanoseconds_per_millisecond), "wire milliseconds must become the original monotonic lifetime");
}

void agentTransitionsPublishOnlyAfterACommittedRevision() {
  SystemAllocator memory;
  Transport transport;
  Client client{memory, transport};
  std::array entries{agentSnapshotEntry()};
  entries.front().display_name = "Custom provider";
  entries.front().status = AgentStatus::blocked;
  Clock::now_ns = second;
  deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
  require(client.notifications().items().empty(), "an initial blocked agent must not invent a transition");
  entries.front().status = AgentStatus::working;
  deliver(client, AgentSnapshot{.revision = 2, .entries = entries});
  entries.front().status = AgentStatus::blocked;
  Clock::now_ns = 2 * second;
  deliver(client, AgentSnapshot{.revision = 3, .entries = entries});
  require(client.notifications().items().size() == 1 && client.notifications().items().front().message.view() == "Custom provider in pane 1 is waiting for input", "committed transitions must use current provider metadata");
  const auto revision = client.notificationRevision();
  deliver(client, AgentSnapshot{.revision = 3, .entries = entries});
  require(client.notificationRevision() == revision, "stale snapshots must not extend alert lifetimes");
  client.disconnected();
  entries.front().status = AgentStatus::failed;
  deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
  require(client.notificationRevision() == revision, "source replacement must retain old notices without comparing retired agent identities");
}

void routedDismissalCompletesOnceAndPreservesItsRoute() {
  SystemAllocator memory;
  Transport transport;
  Client client{memory, transport};
  Clock::now_ns = second;
  client.publishNotification({.title = "Dismiss me", .message = {}, .link = {}});
  Clock::now_ns += NotificationItem::transition_duration_ns;
  client.advanceNotifications(Clock::now_ns);
  const auto id = client.notifications().items().front().id;
  ClientCommand command{.request_id = 1, .route = {.id = 2, .generation = 3}, .action = ClientAction::notification_dismiss, .target_id = id.value};
  require(deliver(client, command) == Change::notification, "routed dismissal must notify the host scheduler");
  const auto completed = transport.last<CompleteClientCommand>();
  require(completed.status == ClientCommandStatus::applied && completed.target_id == id.value && completed.route.id == command.route.id && completed.route.generation == command.route.generation, "successful dismissal must preserve the routed reply identity");
  require(client.notifications().items().front().phase == NotificationItem::Phase::exiting, "dismissal must preserve the original fade instead of deleting immediately");
  const auto revision = client.notificationRevision();
  ++command.request_id;
  require(deliver(client, command) == Change::none, "a repeated dismissal must not restart its transition");
  const auto repeated = transport.last<CompleteClientCommand>();
  require(repeated.status == ClientCommandStatus::failed && repeated.text == "NotificationNotFound" && client.notificationRevision() == revision, "a stale routed action must return the original bounded failure");
  Clock::now_ns += NotificationItem::transition_duration_ns;
  client.advanceNotifications(Clock::now_ns);
  require(client.notifications().items().empty(), "a completed fade must remove its retained payload");
}

void activationNavigatesBySemanticTargetOnce() {
  SystemAllocator memory;
  Transport transport;
  Client client{memory, transport};
  openFirstPane(client, transport);
  std::array entries{agentSnapshotEntry()};
  entries.front().pane_id = 2;
  entries.front().location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 2};
  deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
  Clock::now_ns = second;
  client.publishNotification({.target = {.kind = NotificationTarget::Kind::pane, .id = 2}, .title = "Open pane", .message = {}, .link = {}});
  const auto pane_notice = client.notifications().items().front().id;
  require(client.activateNotification(pane_notice) && client.activeTab()->location.tab_id == 2 && client.activeTab()->focused_pane == 2, "an alert for an unseen agent must select its actual pane and workspace");
  const auto acknowledgements = transport.count(ClientTag::acknowledge_agent);
  require(!client.activateNotification(pane_notice) && transport.count(ClientTag::acknowledge_agent) == acknowledgements, "repeated activation must not send duplicate acknowledgements");

  client.publishNotification({.target = {.kind = NotificationTarget::Kind::tab, .id = 1}, .title = "Open tab", .message = {}, .link = {}});
  require(client.activateNotification(client.notifications().items().front().id) && client.activeTab()->location.tab_id == 1, "a tab target must resolve its current workspace membership");
  require(client.notificationTargetVisible({.kind = NotificationTarget::Kind::pane, .id = 1}), "a pane already present in the active layout must be suppressed in presentation");
  client.publishNotification({.target = {.kind = NotificationTarget::Kind::workspace, .id = 2}, .title = "Open workspace", .message = {}, .link = {}});
  require(client.activateNotification(client.notifications().items().front().id) && client.activeTab()->location.workspace.id == 2, "a workspace target must reuse the normal workspace-selection flow");
}

}

int main() try {
  wireMessagesOwnTextAndRetainStructuredActions();
  agentTransitionsPublishOnlyAfterACommittedRevision();
  routedDismissalCompletesOnceAndPreservesItsRoute();
  activationNavigatesBySemanticTargetOnce();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
