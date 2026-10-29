#include "application/session.hpp"
#include "assertions.hpp"
#include "core/memory.hpp"
#include "session_fixture.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

constexpr std::uint64_t project_id = 9;
constexpr std::uint64_t checkout_id = 31;
constexpr std::uint64_t second_checkout_id = 32;
constexpr WorktreeListEntry gone_checkout{.worktree = checkout_id, .source = project_id, .state = WorktreeState::gone, .path = "/project/gone", .branch = "gone"};
constexpr WorktreeListEntry second_gone_checkout{.worktree = second_checkout_id, .source = project_id, .state = WorktreeState::gone, .path = "/project/other", .branch = "other"};

void leavingAWorktreeSelectsItsProjectWithoutCreatingAPane() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  require(!client.leaveWorktree(), "an unconnected client must not request a workspace handoff");
  openFirstPane(client, transport);
  require(!client.leaveWorktree(), "a project without a worktree must stay selected");
  const auto workspace = client.activeTab()->location.workspace;
  const std::array entries{WorkspaceListEntry{.workspace = project_id, .name = "Project", .path = "/project"}, WorkspaceListEntry{.workspace = workspace.id, .name = "Checkout", .path = "/project/checkout"}};
  const std::array worktrees{WorktreeListEntry{.worktree = checkout_id, .source = project_id, .workspace = workspace.id, .path = "/project/checkout", .branch = "checkout"}};
  deliver(client, WorkspaceList{.revision = 1, .entries = entries, .worktrees = worktrees});
  const auto opening_count = transport.count(ClientTag::open_pane);
  require(client.leaveWorktree(), "a linked checkout must request its source project");
  const auto request = transport.last<RequestWorkspaceSnapshot>();
  require(request.workspace.kind == WorkspaceLocation::Kind::workspace && request.workspace.id == project_id, "leaving a worktree must use its source instead of its checkout identity");
  require(transport.count(ClientTag::open_pane) == opening_count && client.focusedPane()->id == 1, "the handoff must await authoritative project metadata without creating a process");
  client.disconnected();
  require(!client.leaveWorktree(), "a disconnected client must not use retained worktree metadata");
}

void forgettingOnlyTargetsGoneCheckoutsWithoutTabs() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  Transport transport;
  {
    Session client{memory, transport};
    openFirstPane(client, transport);
    const std::array worktrees{
        gone_checkout,
        WorktreeListEntry{.worktree = 40, .source = project_id, .state = WorktreeState::active, .path = "/project/active", .branch = "active"},
        WorktreeListEntry{.worktree = 41, .source = project_id, .state = WorktreeState::integrated, .path = "/project/integrated", .branch = "integrated"},
        WorktreeListEntry{.worktree = 42, .source = project_id, .workspace = 2, .state = WorktreeState::gone, .path = "/project/open", .branch = "open"},
        second_gone_checkout,
    };
    deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
    const auto first_message = transport.sent.size();
    require(client.forgetGoneWorktrees() == 2 && transport.count(ClientTag::forget_worktree) == 2, "only gone worktrees without an owning workspace may be forgotten");
    const auto first = Codec::decode<ForgetWorktree>(transport.sent[first_message]);
    const auto second = transport.last<ForgetWorktree>();
    require(first.worktree == checkout_id && second.worktree == second_checkout_id && first.request_id != second.request_id, "cleanup requests must preserve snapshot order and own distinct correlations");
    require(client.workspaceList().worktrees().size() == worktrees.size(), "cleanup must await runtime snapshots instead of mutating its replica");
    require(deliver(client, RequestFailed{.request_id = first.request_id, .code = FailureCode::worktree_not_found, .message = "Already forgotten"}) == Change::none && client.error().empty(), "a concurrently forgotten row must release its correlation without an error");
    require(deliver(client, RequestCompleted{.request_id = second.request_id}) == Change::none, "a successful cleanup must only release request ownership");
    require(client.workspaceList().worktrees().size() == worktrees.size(), "request completion must not substitute for an authoritative snapshot");
    client.disconnected();
    require(client.forgetGoneWorktrees() == 0, "disconnected cleanup must not queue requests against stale state");
  }

  require(memory.liveBytes() == 0, "worktree snapshots and cleanup must release all injected allocations");
}

void cleanupStopsAtCapacityAndReleasesRejectedDelivery() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array worktrees{gone_checkout};
  deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
  constexpr auto capacity = decltype(client)::maximum_pending;
  std::array<std::uint64_t, capacity> requests{};
  for (std::size_t index = 0; index < capacity - 1; ++index) {
    require(client.forgetGoneWorktrees() == 1, "available correlations must admit cleanup");
    requests[index] = transport.last<ForgetWorktree>().request_id;
  }

  transport.reject_forget_worktree = true;
  bool rejected = false;
  try {
    static_cast<void>(client.forgetGoneWorktrees());
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected, "delivery rejection must remain observable to the caller");
  transport.reject_forget_worktree = false;
  const std::array final_rows{gone_checkout, second_gone_checkout};
  deliver(client, WorkspaceList{.revision = 2, .worktrees = final_rows});
  require(client.forgetGoneWorktrees() == 1, "rejected delivery must release its slot and a partially admitted batch must stop at capacity");
  requests.back() = transport.last<ForgetWorktree>().request_id;
  require(client.forgetGoneWorktrees() == 0 && transport.count(ClientTag::forget_worktree) == capacity, "a full tracker must leave remaining cleanup for the next invocation");
  for (const auto request : requests) {
    require(deliver(client, RequestCompleted{.request_id = request}) == Change::none, "each admitted cleanup must retain an independently releasable correlation");
  }

  require(client.forgetGoneWorktrees() == final_rows.size(), "completion must release the entire bounded tracker for later requests");
}

}

int main() {
  try {
    leavingAWorktreeSelectsItsProjectWithoutCreatingAPane();
    forgettingOnlyTargetsGoneCheckoutsWithoutTabs();
    cleanupStopsAtCapacityAndReleasesRejectedDelivery();
    std::cout << "gui-worktree-actions: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-worktree-actions: " << error.what() << '\n';

    return 1;
  }
}
