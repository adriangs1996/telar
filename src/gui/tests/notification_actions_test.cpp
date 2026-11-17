#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "assertions.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <string_view>

#include <exception>
#include <iostream>
#include <limits.h>

import telar.gui.config.plugin_query;
import telar.gui.foundation.actions;
import telar.gui.config.generation;
import telar.gui.input.copy_pointer;

import telar.gui.config.gui_query;
import telar.gui.application;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using telar::gui::test::require;

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

    require(rejected, "retired or forged notification actions must be rejected");
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

      require(expected && expected->title.view() == "Retained notice" && expected->message.view() == "original body", "configured notification values must come from their retained description");
      constexpr std::uint32_t duration_ms = 750;
      constexpr std::uint64_t pane_id = 99;

      require(expected && expected->level == NotificationLevel::warning && expected->duration_ms == duration_ms && expected->target.kind == NotificationTarget::Kind::pane && expected->target.id == pane_id, "description lookup must preserve severity, duration and semantic target");
      static_cast<void>(generation.invoke(generation.input().configured[2].action, {}));
      const auto allocations = budget.allocations();
      constexpr std::size_t repetitions = 100;

      for (std::size_t index = 0; index < repetitions; ++index) {
        const auto notification = generation.notificationAction(binding);

        require(notification && notification->title.view() == "Retained notice" && notification->level == NotificationLevel::warning, "Lua table mutation must not rewrite an already compiled action");
      }

      require(budget.allocations() == allocations, "repeated configured notification lookup must not allocate through the injected allocator");
      require(!generation.notificationAction(generation.input().configured[3].action), "other extended action families must retain their unsupported status");
    }

    require(budget.liveBytes() == 0, "notification descriptions must not retain their configuration allocator after destruction");
  }

  void callbackDescriptionsOwnTextAndRetireTheirRegistryReferences() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    application::ConfigurationGeneration generation{memory, source};
    const auto callback = generation.input().configured[1].action;
    const auto first = generation.invoke(callback, {});

    require(first.length == 1 && first.actions.front().kind == BindingActionKind::extended, "a callback must retain its validated notification effect");
    const auto copied = generation.notificationAction(first.actions.front());

    require(copied && copied->title.view() == "Run 1" && copied->target.kind == NotificationTarget::Kind::workspace && copied->target.id == 2, "callback notification fields must be decoded from their current registry value");
    const auto second = generation.invoke(callback, {});
    const auto next = generation.notificationAction(second.actions.front());

    require(next && next->title.view() == "Run 2" && copied && copied->title.view() == "Run 1", "an owned description must remain usable after another callback replaces transient Lua values");
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

}

int main() try {
  configuredActionsRetainTheirCompiledValuesWithoutAllocating();
  callbackDescriptionsOwnTextAndRetireTheirRegistryReferences();

  return 0;
} catch (const std::exception& error) {
  std::cerr << error.what() << '\n';

  return 1;
}
