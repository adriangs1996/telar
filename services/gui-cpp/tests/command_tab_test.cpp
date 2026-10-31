#include "allocation_gate.hpp"
#include "application/records.hpp"
#include "application/session.hpp"
#include "assertions.hpp"
#include "config/callback.hpp"
#include "config/command_tab_action.hpp"
#include "config/command_tab_reference.hpp"
#include "config/command_tab_registry.hpp"
#include "config/command_tab_view.hpp"
#include "config/generation.hpp"
#include "config/limit_notices.hpp"
#include "core/memory.hpp"
#include "input/action.hpp"
#include "input/tab_drag.hpp"
#include "session_fixture.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <limits>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

template <typename Value>
Value requireValue(std::optional<Value> value) {
  if (!value) {
    throw std::runtime_error{"Required command value is missing"};
  }

  return *value;
}

runtime::config::CommandTabView sampleCommand() {
  runtime::config::CommandTabView command;
  command.arguments[0] = "/bin/echo";
  command.arguments[1] = "quotes ' \" $HOME $(ignored)";
  command.arguments[2] = "中";
  command.count = 3;

  return command;
}

void retainedAndRecentCommandLifetimes() {
  runtime::config::RetainedCommandTabRegistry commands;
  runtime::config::LimitNotices limits;
  const auto command = sampleCommand();
  const auto fixed = requireValue(commands.keepReference(command.argv(), {}, limits));
  require(fixed.epoch == 0, "configuration commands must receive fixed references");
  require(commands.keepReference(command.argv(), {}, limits) == fixed, "equivalent command rows must share their storage and reference");
  commands.seal();
  constexpr std::size_t argument_bytes = 4096;
  const std::string argument(argument_bytes, 'x');
  const std::array<std::string_view, 1> arguments{argument};
  const auto first = requireValue(commands.keepReference(arguments, "first", limits));
  constexpr std::size_t command_count = 128;
  for (std::size_t index = 0; index < command_count; ++index) {
    const auto recent = commands.keepReference(arguments, std::to_string(index), limits);
    require(recent.has_value(), "a callback must regain storage by clearing recent rows");
  }

  require(!commands.load(first), "a cleared recent reference must never name a newer row");
  require(commands.load(fixed).has_value() && commands.keepReference(command.argv(), {}, limits) == fixed, "recent clearing must preserve fixed commands and their deduplication");
}

void commandReferencesPreserveBitPatternsAndRejectMalformedIds() {
  constexpr auto maximum_row_id = std::numeric_limits<std::uint16_t>::max();
  constexpr runtime::config::CommandTabReference original{.epoch = std::numeric_limits<std::uint32_t>::max(), .id = maximum_row_id};
  const auto action = commandTabAction(original, std::numeric_limits<std::uint64_t>::max());
  require(requireValue(commandTabReference(action)) == original, "command actions must preserve every epoch and row-id bit");

  auto invalid = action;
  invalid.kind = BindingActionKind::callback;
  require(!commandTabReference(invalid), "a callback reference must never decode as a command");
  invalid.kind = BindingActionKind::command_tab;
  for (const auto identity : std::array{-1, static_cast<int>(maximum_row_id) + 1}) {
    invalid.reference = identity;
    require(!commandTabReference(invalid), "out-of-range row IDs must be rejected before narrowing");
  }
}

void renderRowsRemainValidUntilTheNextRender() {
  runtime::config::RetainedCommandTabRegistry commands;
  runtime::config::LimitNotices limits;
  const auto command = sampleCommand();
  const auto fixed = requireValue(commands.keepReference(command.argv(), {}, limits));
  commands.seal();
  commands.beginRender();
  constexpr std::size_t argument_bytes = 4096;
  const std::string argument(argument_bytes, 'x');
  const std::array<std::string_view, 1> arguments{argument};
  const auto first = requireValue(commands.keepReference(arguments, "first", limits));
  constexpr std::size_t attempts = 64;
  bool refused = false;
  for (std::size_t index = 0; index < attempts; ++index) {
    refused |= !commands.keepReference(arguments, std::to_string(index), limits);
  }

  require(refused && commands.load(first).has_value(), "a full render must refuse later rows instead of clearing its earlier commands");
  commands.endRender();
  commands.beginRender();
  require(!commands.load(first) && commands.load(fixed).has_value(), "the next render must recover recent capacity without expiring fixed commands");
  commands.endRender();
}

void callbackCommandsRetainValuesAcrossInvocations() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = R"(
          local command=telar.action.command_tab{command={'echo','fixed'},label='fixed'}
          local n=0
          return {api_version=2,client={keybindings={telar.bind({'f'},command),
            telar.bind({'c'},function()
              n=n+1;command.command[2]='mutated'
              return telar.action.command_tab{command={'echo','dynamic '..n},label='callback'}
            end)}}}
        )",
        .directory = {},
        .profile = {},
    };
    ConfigurationGeneration generation{memory, source};
    const auto fixed = generation.input().configured[0].action;
    const auto callback = generation.input().configured[1].action;
    const auto first = generation.invoke(callback, {}).actions[0];
    require(requireValue(generation.commandTab(first)).arguments[1] == "dynamic 1", "callback commands must retain their own argv");
    const auto second = generation.invoke(callback, {}).actions[0];
    require(requireValue(generation.commandTab(second)).arguments[1] == "dynamic 2", "later callback values must be captured independently");
    require(requireValue(generation.commandTab(first)).arguments[1] == "dynamic 1", "command references must survive later callback invocations until their pool epoch expires");
    auto foreign = first;
    ++foreign.generation;
    bool obsolete = false;
    try {
      static_cast<void>(generation.commandTab(foreign));
    } catch (const std::invalid_argument &) {
      obsolete = true;
    }

    require(obsolete, "command references must reject a different configuration generation");
    require(requireValue(generation.commandTab(fixed)).arguments[1] == "fixed", "callback mutation must preserve configured command values");
  }

  require(memory.liveBytes() == 0, "command generations must release every injected allocation");
}

void aLargeBatchCanExpireItsEarlierRecentRows() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
      .source = R"(
        local arguments={};for i=1,32 do arguments[i]=string.rep('x',128) end
        local bindings={}
        for i=1,19 do bindings[i]=telar.bind_global({string.char(96+i)},telar.action.command_tab{
          command=arguments,label=string.format('%032d',i)}) end
        bindings[20]=telar.bind_global({'t'},telar.action.command_tab{
          command={string.rep('x',2000)},label=string.rep('f',32)})
        bindings[21]=telar.bind_global({'z'},function()
          local batch={};for i=1,16 do batch[i]=telar.action.command_tab{
            command=arguments,label=string.format('%032d',100+i)} end
          return batch
        end)
        return {api_version=2,client={keybindings=bindings}}
      )",
      .directory = {},
      .profile = {},
  };
  ConfigurationGeneration generation{memory, source};
  constexpr std::size_t callback_index = 20;
  const auto batch = generation.invoke(generation.input().configured[callback_index].action, {});
  require(batch.length == BindingEffects::maximum_effects, "valid recent commands must not be dropped at the fixed-row budget");
  const auto first = batch.actions[0];
  const auto last = batch.actions[batch.length - 1];
  const auto fixed = generation.input().configured[0].action;
  require(!generation.commandTab(first) && generation.commandTab(last).has_value(), "pool clearing must expire earlier batch references while retaining later commands");
  require(generation.commandTab(fixed).has_value(), "a large callback batch must preserve its configuration's commands");
}

void commandRequestsPreserveLaunchAndRecoverFromDeliveryFailure() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  const auto command = sampleCommand();
  require(client.createCommandTab(command) == TabCreationOutcome::unavailable, "a command requires an attached focused launch source");
  openFirstPane(client, transport);
  transport.reject_create_tab = true;
  bool rejected = false;
  try {
    static_cast<void>(client.createCommandTab(command));
  } catch (const EncodingError &) {
    rejected = true;
  }

  transport.reject_create_tab = false;
  require(rejected && client.createCommandTab(command) == TabCreationOutcome::requested, "failed delivery must release tab-operation ownership for retry");
  const auto request = transport.last<CreateTab>();
  require(request.launch.cwd_source == 1 && request.label == "echo", "a command tab must inherit its focused pane's cwd and resolve its label");
  require(request.launch.arguments.size() == command.count && request.launch.arguments[1] == command.arguments[1] && request.launch.arguments[2] == command.arguments[2], "tab requests must preserve argv boundaries without shell interpretation");
  require(client.createCommandTab(command) == TabCreationOutcome::busy && transport.count(ClientTag::create_tab) == 1, "a pending tab operation must refuse a second command");
  const TabLocation created{.workspace = request.workspace, .tab_id = 2};
  deliver(client, TabCreated{.request_id = request.request_id, .location = created, .position = 1, .label = "echo", .root_pane_id = 2, .pane_generation = 1});
  require(sameTab(client.activeTab()->location, created) && client.focusedPane()->id == 2, "a confirmed command tab must become active");
  require(client.createCommandTab(command) == TabCreationOutcome::requested, "confirmation must release tab-operation ownership");
}

std::size_t adoptCommandWithAllocationBudget(std::optional<std::size_t> budget, bool discover_before_confirmation) {
  SystemAllocator system;
  BudgetAllocator counted{system, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{counted};
  Transport transport;
  std::size_t allocations = 0;
  {
    Session client{memory, transport};
    openFirstPane(client, transport);
    client.createTab();
    const auto request = transport.last<CreateTab>();
    constexpr std::string_view discovered_application = "foreground_process_requiring_heap_storage";
    if (discover_before_confirmation) {
      const std::array foregrounds{PaneForeground{.pane_id = 2, .name = discovered_application}};
      const std::array descriptors{
          TabDescriptor{.tab_id = 1, .position = 0, .pane_count = 1},
          TabDescriptor{.tab_id = 2, .position = 1, .pane_count = 1, .foregrounds = foregrounds},
      };
      deliver(client, WorkspaceSnapshot{.request_id = request.request_id, .workspace = request.workspace, .name = "workspace", .tabs = descriptors});
    }

    const auto previous_count = client.tabs().size();
    const auto before = counted.allocations();
    memory.permit(budget);
    bool rejected = false;
    try {
      deliver(client, TabCreated{.request_id = request.request_id, .location = {.workspace = request.workspace, .tab_id = 2}, .position = 1, .label = "command", .root_pane_id = 2, .pane_generation = 1});
    } catch (const std::bad_alloc &) {
      rejected = true;
    }

    allocations = counted.allocations() - before;
    memory.permit(std::nullopt);
    if (budget) {
      require(rejected && client.tabs().size() == previous_count && client.focusedPane()->id == 1 && client.findPane(2) == nullptr, "failed command adoption must preserve existing tabs, panes and focus");
      if (discover_before_confirmation) {
        require(client.tabs().back()->applicationName(nullptr) == discovered_application, "failed confirmation must preserve the discovered foreground");
      }
    } else {
      require(!rejected && client.tabs().size() == 2 && client.focusedPane()->id == 2, "a complete allocation budget must adopt the confirmed command");
      if (discover_before_confirmation) {
        require(client.activeTab()->applicationName(client.focusedPane()) == discovered_application, "confirmation must preserve the discovered foreground for the newly adopted pane");
      }
    }
  }

  require(counted.liveBytes() == 0, "partial command adoption must release every allocation");

  return allocations;
}

void commandAdoptionIsAtomicAcrossAllocationFailures() {
  for (const bool discover_before_confirmation : {false, true}) {
    const auto allocations = adoptCommandWithAllocationBudget(std::nullopt, discover_before_confirmation);
    for (std::size_t permitted = 0; permitted < allocations; ++permitted) {
      static_cast<void>(adoptCommandWithAllocationBudget(permitted, discover_before_confirmation));
    }
  }
}

void discoveryBeforeConfirmationDoesNotDuplicateTheCreatedTab() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto command = sampleCommand();
  require(client.createCommandTab(command) == TabCreationOutcome::requested, "a command must start its correlated tab operation");
  const auto request = transport.last<CreateTab>();
  const std::array descriptors{
      TabDescriptor{.tab_id = 1, .position = 0, .pane_count = 1, .label = "source"},
      TabDescriptor{.tab_id = 2, .position = 1, .pane_count = 1, .label = "echo"},
  };
  deliver(client, WorkspaceSnapshot{.request_id = request.request_id, .workspace = request.workspace, .name = "workspace", .tabs = descriptors});
  require(client.tabs().size() == 2 && client.focusedPane()->id == 1, "discovery may expose a tab's metadata without adopting its pane or focus");
  require(client.createCommandTab(command) == TabCreationOutcome::busy, "discovery must not complete the creation request");
  deliver(client, TabCreated{.request_id = request.request_id, .location = {.workspace = request.workspace, .tab_id = 2}, .position = 1, .label = "echo", .root_pane_id = 2, .pane_generation = 1});
  require(client.tabs().size() == 2 && client.focusedPane()->id == 2, "confirmation must adopt an unloaded discovered tab without duplication");
}

void confirmationCannotReplaceALiveTab() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.createTab();
  const auto request = transport.last<CreateTab>();
  bool rejected = false;
  try {
    deliver(client, TabCreated{.request_id = request.request_id, .location = {.workspace = request.workspace, .tab_id = 1}, .position = 0, .label = "incorrect", .root_pane_id = 3, .pane_generation = 1});
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && client.tabs().size() == 1 && client.focusedPane()->id == 1, "a correlated reply must not replace an already adopted tab");
}

void openThreeTabs(Session<SystemAllocator, Transport> &client, Transport &transport) {
  openFirstPane(client, transport);
  for (std::uint16_t position = 1; position <= 2; ++position) {
    client.createTab();
    const auto request = transport.last<CreateTab>();
    const auto identity = static_cast<std::uint64_t>(position) + 1;
    deliver(client, TabCreated{.request_id = request.request_id, .location = {.workspace = request.workspace, .tab_id = identity}, .position = position, .label = "command", .root_pane_id = identity, .pane_generation = 1});
  }
}

void commandsShareOperationOwnershipWithRenameMoveAndClose() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openThreeTabs(client, transport);
  const auto command = sampleCommand();
  client.renameTab("renamed");
  const auto rename = transport.last<RenameTab>();
  require(client.createCommandTab(command) == TabCreationOutcome::busy, "rename and command creation must share tab-operation ownership");
  deliver(client, TabRenamed{.request_id = rename.request_id, .location = rename.location, .label = "renamed"});
  client.moveTab(TabMoveDirection::previous);
  const auto move = transport.last<MoveTab>();
  require(client.createCommandTab(command) == TabCreationOutcome::busy, "moving a tab must retain ownership until its confirmation");
  deliver(client, TabMoved{.request_id = move.request_id, .location = move.location, .position = 1});
  require(client.activeTab()->position == 1, "the runtime's confirmed position must be adopted");
  for (const auto &tab : client.tabs()) {
    if (tab->location.tab_id == 2) {
      require(tab->position == 2, "moving one tab must shift its displaced neighbor");
    }
  }

  client.closeTab(client.activeTab()->location);
  const auto close = transport.last<CloseTab>();
  require(client.createCommandTab(command) == TabCreationOutcome::busy, "closing a tab must retain the same operation owner");
  deliver(client, RequestFailed{.request_id = close.request_id, .code = FailureCode::invalid_request, .message = "close failed"});
  require(client.createCommandTab(command) == TabCreationOutcome::requested, "a rejected operation must allow the next command tab");
}

void draggingRetainsTheExplicitSourceAndCanonicalOperationOwner() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openThreeTabs(client, transport);
  const auto workspace = client.activeTab()->location.workspace;
  const TabDragMove move{.location = {.workspace = workspace, .tab_id = 1}, .direction = TabMoveDirection::next, .relative_to = 3};
  const auto source = std::ranges::find_if(client.tabs(), [](const auto &tab) {
    return tab->location.tab_id == 1;
  });
  require(source != client.tabs().end(), "the captured source must be present");
  require(client.requestTabMove(move), "a drag must move its captured source even when another tab has focus");
  const auto request = transport.last<MoveTab>();
  require(request.location.tab_id == 1 && request.relative_to == 3 && request.direction == TabMoveDirection::next, "the request must preserve the source and anchor identities");
  require(client.activeTab()->location.tab_id == 3 && (*source)->position == 0, "a move request must preserve focus and wait for canonical order");
  require(!client.requestTabMove(move), "a pending drag must retain the shared tab-operation owner");
  deliver(client, TabMoved{.request_id = request.request_id, .location = request.location, .position = 2});
  require((*source)->position == 2 && client.activeTab()->location.tab_id == 3, "confirmation must reorder the captured source without stealing focus");

  auto invalid = move;
  invalid.location.workspace.id += 1;
  require(!client.requestTabMove(invalid), "a drag must never move a source from a replaced workspace");
  invalid = move;
  invalid.location.tab_id = 4;
  require(!client.requestTabMove(invalid), "a retired source must not create a request");
  invalid = move;
  invalid.relative_to = move.location.tab_id;
  require(!client.requestTabMove(invalid), "a source cannot anchor its own move");
  invalid.relative_to = 4;
  require(!client.requestTabMove(invalid), "a retired destination must not create a request");
  require(client.requestTabMove(move), "rejected gestures must leave tab-operation admission available");
}

void closingACommandReturnsToTheAdjacentTab() {
  struct ClosureCase {
    std::uint64_t active;
    std::uint64_t closing;
    std::uint64_t selected;
  };

  constexpr auto cases = std::to_array<ClosureCase>({
      {.active = 1, .closing = 1, .selected = 2},
      {.active = 2, .closing = 2, .selected = 3},
      {.active = 3, .closing = 3, .selected = 2},
      {.active = 3, .closing = 1, .selected = 3},
  });
  for (const auto &entry : cases) {
    SystemAllocator memory;
    Transport transport;
    Session client{memory, transport};
    openThreeTabs(client, transport);
    const auto workspace = client.activeTab()->location.workspace;
    client.selectTab({.workspace = workspace, .tab_id = entry.active});
    deliver(client, PaneExited{.pane_id = entry.closing, .kind = ExitKind::exited});
    deliver(client, TabClosed{.location = {.workspace = workspace, .tab_id = entry.closing}});
    require(client.activeTab()->location.tab_id == entry.selected, "closing a command must preserve surviving focus or select its next neighbor before its previous neighbor");
  }
}

}

int main() {
  try {
    retainedAndRecentCommandLifetimes();
    commandReferencesPreserveBitPatternsAndRejectMalformedIds();
    renderRowsRemainValidUntilTheNextRender();
    callbackCommandsRetainValuesAcrossInvocations();
    aLargeBatchCanExpireItsEarlierRecentRows();
    commandRequestsPreserveLaunchAndRecoverFromDeliveryFailure();
    closingACommandReturnsToTheAdjacentTab();
    commandsShareOperationOwnershipWithRenameMoveAndClose();
    draggingRetainsTheExplicitSourceAndCanonicalOperationOwner();
    discoveryBeforeConfirmationDoesNotDuplicateTheCreatedTab();
    confirmationCannotReplaceALiveTab();
    commandAdoptionIsAtomicAcrossAllocationFailures();
    std::puts("gui-command-tab: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-command-tab: " << error.what() << '\n';

    return 1;
  }
}
