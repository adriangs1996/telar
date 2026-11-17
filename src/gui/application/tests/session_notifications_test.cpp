#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/protocol/clients.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string>
#include <string_view>

import telar.testing;
import telar.gui.tests.agent_fixture;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.features.notifications;
import telar.wire.agents;
import telar.wire.layout;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;
  using telar::gui::test::agentSnapshotEntry;
  using namespace telar::gui::application::tests::session_fixture;

  struct Clock {
    static inline std::uint64_t now_ns = 0;

    static std::uint64_t nowNanoseconds() noexcept {
      return now_ns;
    }
  };

  // A session that reads `Clock`.
  struct Client : telar::gui::application::tests::session_fixture::TestSession<SystemAllocator> {
    Client(SystemAllocator& memory, Transport& transport)
        : TestSession(memory, transport, &Clock::nowNanoseconds) {}
  };

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
    check(deliver(client, message) == application::Change::notification, "a wire notification must publish a dedicated view change");
    title.assign("modified");
    body.assign("modified");
    link.assign("https://other.example");
    const auto& notice = application::notifications::center(client).items().front();

    check(notice.title.view() == "Review required" && notice.message.view() == "The build needs a decision" && notice.link.view() == "https://example.com/build", "notification text must outlive wire decoding and caller mutations");
    check(notice.level == NotificationLevel::warning && notice.target.kind == NotificationTarget::Kind::tab && notice.target.id == 2, "wire metadata must remain structured for rendering and activation");
    check(notice.expires_at_ns == second + NotificationItem::transition_duration_ns + (min_notification_duration_ms * NotificationInput::nanoseconds_per_millisecond), "wire milliseconds must become the original monotonic lifetime");
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
    check(application::notifications::center(client).items().empty(), "an initial blocked agent must not invent a transition");
    entries.front().status = AgentStatus::working;
    deliver(client, AgentSnapshot{.revision = 2, .entries = entries});
    entries.front().status = AgentStatus::blocked;
    Clock::now_ns = 2 * second;
    deliver(client, AgentSnapshot{.revision = 3, .entries = entries});
    check(application::notifications::center(client).items().size() == 1 && application::notifications::center(client).items().front().message.view() == "Custom provider in pane 1 is waiting for input", "committed transitions must use current provider metadata");
    const auto revision = application::notifications::revision(client);

    deliver(client, AgentSnapshot{.revision = 3, .entries = entries});
    check(application::notifications::revision(client) == revision, "stale snapshots must not extend alert lifetimes");
    client.disconnected();
    entries.front().status = AgentStatus::failed;
    deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
    check(application::notifications::revision(client) == revision, "source replacement must retain old notices without comparing retired agent identities");
  }

  void routedDismissalCompletesOnceAndPreservesItsRoute() {
    SystemAllocator memory;
    Transport transport;
    Client client{memory, transport};

    Clock::now_ns = second;
    application::notifications::publish(client, {.title = "Dismiss me", .message = {}, .link = {}});
    Clock::now_ns += NotificationItem::transition_duration_ns;
    application::notifications::advance(client, Clock::now_ns);
    const auto id = application::notifications::center(client).items().front().id;
    ClientCommand command{.request_id = 1, .route = {.id = 2, .generation = 3}, .action = ClientAction::notification_dismiss, .target_id = id.value};

    check(deliver(client, command) == application::Change::notification, "routed dismissal must notify the host scheduler");
    const auto completed = transport.last<CompleteClientCommand>();

    check(completed.status == ClientCommandStatus::applied && completed.target_id == id.value && completed.route.id == command.route.id && completed.route.generation == command.route.generation, "successful dismissal must preserve the routed reply identity");
    check(application::notifications::center(client).items().front().phase == NotificationItem::Phase::exiting, "dismissal must preserve the original fade instead of deleting immediately");
    const auto revision = application::notifications::revision(client);

    ++command.request_id;
    check(deliver(client, command) == application::Change::none, "a repeated dismissal must not restart its transition");
    const auto repeated = transport.last<CompleteClientCommand>();

    check(repeated.status == ClientCommandStatus::failed && repeated.text == "NotificationNotFound" && application::notifications::revision(client) == revision, "a stale routed action must return the original bounded failure");
    Clock::now_ns += NotificationItem::transition_duration_ns;
    application::notifications::advance(client, Clock::now_ns);
    check(application::notifications::center(client).items().empty(), "a completed fade must remove its retained payload");
  }

  void activationNavigatesBySemanticTargetOnce() {
    SystemAllocator memory;
    Transport transport;
    Client client{memory, transport};

    openFirstPane(client, transport);
    const std::array workspaces{WorkspaceListEntry{.workspace = 1, .name = "First", .path = "/first"}, WorkspaceListEntry{.workspace = 2, .name = "Second", .path = "/second"}};

    deliver(client, WorkspaceList{.revision = 1, .entries = workspaces});
    std::array entries{agentSnapshotEntry()};

    entries.front().pane_id = 2;
    entries.front().location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 2};
    deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
    Clock::now_ns = second;
    application::notifications::publish(client, {.target = {.kind = NotificationTarget::Kind::pane, .id = 2}, .title = "Open pane", .message = {}, .link = {}});
    const auto pane_notice = application::notifications::center(client).items().front().id;

    check(application::notifications::activate(client, pane_notice) && client.activeTab()->location.tab_id == 2 && client.activeTab()->focused_pane == 2, "an alert for an unseen agent must select its actual pane and workspace");
    const auto destination = entries.front().location;
    const std::array destination_panes{PaneDescriptor{.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = destination, .panes = destination_panes});
    const auto arrival = transport.last<OpenPane>();

    deliver(client, PaneOpened{.request_id = arrival.request_id, .pane_id = 2, .location = destination, .pane_generation = 1});
    check(!client.requestsPending(), "the unseen-pane notification must finish its canonical attachment and tab snapshot");
    const auto acknowledgements = transport.count(ClientTag::acknowledge_agent);

    check(!application::notifications::activate(client, pane_notice) && transport.count(ClientTag::acknowledge_agent) == acknowledgements, "repeated activation must not send duplicate acknowledgements");

    application::notifications::publish(client, {.target = {.kind = NotificationTarget::Kind::tab, .id = 1}, .title = "Open tab", .message = {}, .link = {}});
    check(application::notifications::activate(client, application::notifications::center(client).items().front().id) && client.activeTab()->location.tab_id == 1, "a tab target must resolve its current workspace membership");
    const auto returning = transport.last<OpenPane>();

    deliver(client, PaneOpened{.request_id = returning.request_id, .pane_id = 1, .location = client.activeTab()->location, .pane_generation = 1});
    check(!client.requestsPending(), "returning to an already loaded tab must complete its pane attachment");
    check(application::notifications::targetVisible(client, {.kind = NotificationTarget::Kind::pane, .id = 1}), "a pane already present in the active layout must be suppressed in presentation");
    application::notifications::publish(client, {.target = {.kind = NotificationTarget::Kind::workspace, .id = 2}, .title = "Open workspace", .message = {}, .link = {}});
    check(application::notifications::activate(client, application::notifications::center(client).items().front().id), "a workspace notification must be admitted once");
    const auto opening = transport.last<OpenPane>();

    check(opening.target.kind == PaneTarget::Kind::workspace && opening.target.id == destination.workspace.id, "workspace activation must request the canonical destination through the normal selection flow");
    deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = 2, .location = destination, .pane_generation = 1});
    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = destination, .panes = destination_panes});
    const std::array destination_tabs{TabDescriptor{.tab_id = destination.tab_id, .pane_count = 1}};

    deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = destination.workspace, .name = "Second", .tabs = destination_tabs});
    check(!client.requestsPending() && client.activeTab()->location.workspace.id == destination.workspace.id, "canonical workspace arrival must complete before presenting the notification's target");
  }

  const telar::testing::Case case_wire_messages_own_text_and_retain_structured_actions{"session_notifications.wire_messages_own_text_and_retain_structured_actions", wireMessagesOwnTextAndRetainStructuredActions};
  const telar::testing::Case case_agent_transitions_publish_only_after_a_committed_revision{"session_notifications.agent_transitions_publish_only_after_a_committed_revision", agentTransitionsPublishOnlyAfterACommittedRevision};
  const telar::testing::Case case_routed_dismissal_completes_once_and_preserves_its_route{"session_notifications.routed_dismissal_completes_once_and_preserves_its_route", routedDismissalCompletesOnceAndPreservesItsRoute};
  const telar::testing::Case case_activation_navigates_by_semantic_target_once{"session_notifications.activation_navigates_by_semantic_target_once", activationNavigatesBySemanticTargetOnce};

}
