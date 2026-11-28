#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <string_view>

#include <climits>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.foundation.actions;

import telar.gui.application;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;

  constexpr application::ConfigurationSourceText source{
      .source = R"(
      local fixed = telar.action.notification{
        title='Retained notice',body='original body',level='warning',duration_ms=750,pane_id=99
      }
      local calls = 0
      return {api_version=2,client={
        panels={details=telar.panel{command={'true'}}},
        keybindings={
          telar.bind({'n'},fixed),
          telar.bind({'c'},function()
            calls = calls + 1
            return telar.action.notification{
              title='Run '..calls,body='callback body',level='failure',duration_ms=1200,workspace_id=2
            }
          end),
          telar.bind({'m'},function()
            fixed.title='mutated';fixed.body='mutated';fixed.level='success'
            return {}
          end),
          telar.bind({'p'},telar.action.open_panel('details'))
        }
      }}
    )",
      .directory = {},
      .profile = {},
  };

  template <typename Read>
  void rejects(Read read) {
    bool rejected = false;

    try {
      read();
    } catch (const std::invalid_argument&) {
      rejected = true;
    }

    check(rejected, "retired or forged notification actions must be rejected");
  }

  void configuredActionsRetainTheirCompiledValuesWithoutAllocating() {
    SystemAllocator system;
    constexpr std::size_t budget_bytes = std::size_t{8} * 1024 * 1024;
    BudgetAllocator budget{system, budget_bytes};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      application::ConfigurationGeneration generation{memory, source};
      const auto binding = generation.input().configured[0].action;
      const auto expected = generation.notificationAction(binding);

      check(expected && expected->title.view() == "Retained notice" && expected->message.view() == "original body", "configured notification values must come from their retained description");
      constexpr std::uint32_t duration_ms = 750;
      constexpr std::uint64_t pane_id = 99;

      check(expected && expected->level == NotificationLevel::warning && expected->duration_ms == duration_ms && expected->target.kind == NotificationTarget::Kind::pane && expected->target.id == pane_id, "description lookup must preserve severity, duration and semantic target");
      static_cast<void>(generation.invoke(generation.input().configured[2].action, {}));
      const auto allocations = budget.allocations();
      constexpr std::size_t repetitions = 100;

      for (std::size_t index = 0; index < repetitions; ++index) {
        const auto notification = generation.notificationAction(binding);

        check(notification && notification->title.view() == "Retained notice" && notification->level == NotificationLevel::warning, "Lua table mutation must not rewrite an already compiled action");
      }

      check(budget.allocations() == allocations, "repeated configured notification lookup must not allocate through the injected allocator");
      check(!generation.notificationAction(generation.input().configured[3].action), "other extended action families must retain their unsupported status");
    }

    check(budget.liveBytes() == 0, "notification descriptions must not retain their configuration allocator after destruction");
  }

  void callbackDescriptionsOwnTextAndRetireTheirRegistryReferences() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    application::ConfigurationGeneration generation{memory, source};
    const auto callback = generation.input().configured[1].action;
    const auto first = generation.invoke(callback, {});

    check(first.length == 1 && first.actions.front().kind == BindingActionKind::extended, "a callback must retain its validated notification effect");
    const auto copied = generation.notificationAction(first.actions.front());

    check(copied && copied->title.view() == "Run 1" && copied->target.kind == NotificationTarget::Kind::workspace && copied->target.id == 2, "callback notification fields must be decoded from their current registry value");
    const auto second = generation.invoke(callback, {});
    const auto next = generation.notificationAction(second.actions.front());

    check(next && next->title.view() == "Run 2" && copied && copied->title.view() == "Run 1", "an owned description must remain usable after another callback replaces transient Lua values");
    static_cast<void>(generation.invoke(generation.input().configured[2].action, {}));
    rejects([&] {
      static_cast<void>(generation.notificationAction(second.actions.front()));
    });

    auto obsolete = generation.input().configured[0].action;

    ++obsolete.generation;
    rejects([&] {
      static_cast<void>(generation.notificationAction(obsolete));
    });

    auto forged = generation.input().configured[0].action;

    ++forged.parameter;
    rejects([&] {
      static_cast<void>(generation.notificationAction(forged));
    });
  }

  const telar::testing::Case case_configured_actions_retain_their_compiled_values_without_allocating{"notification_actions.configured_actions_retain_their_compiled_values_without_allocating", configuredActionsRetainTheirCompiledValuesWithoutAllocating};
  const telar::testing::Case case_callback_descriptions_own_text_and_retire_their_registry_references{"notification_actions.callback_descriptions_own_text_and_retire_their_registry_references", callbackDescriptionsOwnTextAndRetireTheirRegistryReferences};

}
