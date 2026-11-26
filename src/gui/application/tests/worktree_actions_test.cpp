#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <span>
#include <string_view>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.layout;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.wire.pane_io;
import telar.base.memory.allocators;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  constexpr std::uint64_t project_id = 9;
  constexpr std::uint64_t checkout_id = 31;
  constexpr std::uint64_t second_checkout_id = 32;
  constexpr WorktreeListEntry gone_checkout{.worktree = checkout_id, .source = project_id, .state = WorktreeState::gone, .path = "/project/gone", .branch = "gone"};
  constexpr WorktreeListEntry second_gone_checkout{.worktree = second_checkout_id, .source = project_id, .state = WorktreeState::gone, .path = "/project/other", .branch = "other"};

  void leavingAWorktreeOpensItsProjectWithoutALaunchCommand() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    check(!application::workbench::leaveWorktree(client), "an unconnected client must not request a workspace handoff");
    openFirstPane(client, transport);
    check(!application::workbench::leaveWorktree(client), "a project without a worktree must stay selected");
    const auto workspace = client.activeTab()->location.workspace;
    const ds::Array entries{WorkspaceListEntry{.workspace = project_id, .name = "Project", .path = "/project"}, WorkspaceListEntry{.workspace = workspace.id, .name = "Checkout", .path = "/project/checkout"}};
    const ds::Array worktrees{WorktreeListEntry{.worktree = checkout_id, .source = project_id, .workspace = workspace.id, .path = "/project/checkout", .branch = "checkout"}};

    deliver(client, WorkspaceList{.revision = 1, .entries = entries, .worktrees = worktrees});
    const auto opening_count = transport.count(ClientTag::open_pane);

    check(application::workbench::leaveWorktree(client), "a linked checkout must request its source project");
    const auto request = transport.last<OpenPane>();

    check(request.target.kind == PaneTarget::Kind::workspace && request.target.id == project_id && !request.launch, "leaving a worktree must open its source workspace without sending a new launch command");
    check(transport.count(ClientTag::open_pane) == opening_count + 1 && transport.count(ClientTag::detach_pane) == 1 && client.activeTab() == nullptr && client.panes.empty(), "the handoff must retire its checkout only after queuing the source project's canonical open");
    client.disconnected();
    check(!application::workbench::leaveWorktree(client), "a disconnected client must not use retained worktree metadata");
  }

  void forgettingOnlyTargetsGoneCheckoutsWithoutTabs() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    Transport transport;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      const ds::Array worktrees{
          gone_checkout,
          WorktreeListEntry{.worktree = 40, .source = project_id, .state = WorktreeState::active, .path = "/project/active", .branch = "active"},
          WorktreeListEntry{.worktree = 41, .source = project_id, .state = WorktreeState::integrated, .path = "/project/integrated", .branch = "integrated"},
          WorktreeListEntry{.worktree = 42, .source = project_id, .workspace = 2, .state = WorktreeState::gone, .path = "/project/open", .branch = "open"},
          second_gone_checkout,
      };

      deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
      const auto first_message = transport.sent.size();

      check(application::workbench::forgetGoneWorktrees(client) == 2 && transport.count(ClientTag::forget_worktree) == 2, "only gone worktrees without an owning workspace may be forgotten");
      const auto first = Codec::decode<ForgetWorktree>(transport.sent[first_message]);
      const auto second = transport.last<ForgetWorktree>();

      check(first.worktree == checkout_id && second.worktree == second_checkout_id && first.request_id != second.request_id, "cleanup requests must preserve snapshot order and own distinct correlations");
      check(client.workspace_list.worktrees().size() == worktrees.size(), "cleanup must await runtime snapshots instead of mutating its replica");
      check(deliver(client, RequestFailed{.request_id = first.request_id, .code = FailureCode::worktree_not_found, .message = "Already forgotten"}) == application::Change::none && client.error().empty(), "a concurrently forgotten row must release its correlation without an error");
      check(deliver(client, RequestCompleted{.request_id = second.request_id}) == application::Change::none, "a successful cleanup must only release request ownership");
      check(client.workspace_list.worktrees().size() == worktrees.size(), "request completion must not substitute for an authoritative snapshot");
      client.disconnected();
      check(application::workbench::forgetGoneWorktrees(client) == 0, "disconnected cleanup must not queue requests against stale state");
    }

    check(budget.liveBytes() == 0, "worktree snapshots and cleanup must release all injected allocations");
  }

  void cleanupStopsAtCapacityAndReleasesRejectedDelivery() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const ds::Array worktrees{gone_checkout};

    deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
    constexpr auto capacity = decltype(client)::maximum_pending;
    ds::Array<std::uint64_t, capacity> requests{};

    for (std::size_t index = 0; index < capacity - 1; ++index) {
      check(application::workbench::forgetGoneWorktrees(client) == 1, "available correlations must admit cleanup");
      requests.atMut(index) = transport.last<ForgetWorktree>().request_id;
    }

    transport.reject_forget_worktree = true;
    bool rejected = false;

    try {
      static_cast<void>(application::workbench::forgetGoneWorktrees(client));
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected, "delivery rejection must remain observable to the caller");
    transport.reject_forget_worktree = false;
    const ds::Array final_rows{gone_checkout, second_gone_checkout};

    deliver(client, WorkspaceList{.revision = 2, .worktrees = final_rows});
    check(application::workbench::forgetGoneWorktrees(client) == 1, "rejected delivery must release its slot and a partially admitted batch must stop at capacity");
    requests.atMut(requests.size() - 1) = transport.last<ForgetWorktree>().request_id;
    check(application::workbench::forgetGoneWorktrees(client) == 0 && transport.count(ClientTag::forget_worktree) == capacity, "a full tracker must leave remaining cleanup for the next invocation");
    for (const auto request : requests) {
      check(deliver(client, RequestCompleted{.request_id = request}) == application::Change::none, "each admitted cleanup must retain an independently releasable correlation");
    }

    check(application::workbench::forgetGoneWorktrees(client) == final_rows.size(), "completion must release the entire bounded tracker for later requests");
  }

  const telar::testing::Case case_leaving_a_worktree_opens_its_project_without_a_launch_command{"worktree_actions.leaving_a_worktree_opens_its_project_without_a_launch_command", leavingAWorktreeOpensItsProjectWithoutALaunchCommand};
  const telar::testing::Case case_forgetting_only_targets_gone_checkouts_without_tabs{"worktree_actions.forgetting_only_targets_gone_checkouts_without_tabs", forgettingOnlyTargetsGoneCheckoutsWithoutTabs};
  const telar::testing::Case case_cleanup_stops_at_capacity_and_releases_rejected_delivery{"worktree_actions.cleanup_stops_at_capacity_and_releases_rejected_delivery", cleanupStopsAtCapacityAndReleasesRejectedDelivery};

}
