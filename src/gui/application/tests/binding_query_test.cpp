#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string_view>

#include "telar_base/memory/allocator.hpp"
#include <string>

#include <climits>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.tests.json_fixture;
import telar.gui.features.configuration;
import telar.gui.application;
import telar.base.text.json;
import telar.plugins;
import telar.base.ds;
import telar.gui.foundation.core;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::configuration;
  using telar::gui::test::requiredJsonField;

  template <Allocator Memory>
  std::string query(const application::ConfigurationGeneration<Memory>& generation, std::size_t index) {
    telar::ds::Array<char, ConfigurationQuery::capacity> output{};

    return std::string{BindingQuery::write(generation.input(), index, generation.actionDescriptions(), generation.commandTabs(), output.viewMut())};
  }

  void configuredOrderAndCallbackReferences() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
        return {api_version=2,client={keybindings={telar.bind({'z'},function() return telar.action.new_tab() end)}},
          profiles={chosen={client={prefix='alt+中',keybindings={
            telar.bind_global({'z'},telar.action.select_tab{index=256}),
            telar.bind({'s'},function() return telar.action.toggle_sidebar() end),
            telar.bind_expr({'e'},function() return telar.input.consume() end)}}}}}
      )",
        .directory = {},
        .profile = "chosen",
        .generation = 42,
    };

    const application::ConfigurationGeneration generation{memory, source};
    const auto first = query(generation, 0);

    check(first.contains(R"("index":0,"prefixed":false)") && first.contains(R"("action":{"type":"select_tab","value":255})"), "binding queries must use configured order and zero-based semantic indices");
    const auto callback = query(generation, 1);

    check(callback.contains(R"("bytes":"中\u0000","len":3)") && callback.contains(R"("type":"lua_callback","value":{"generation":42,"id":1})"), "profile callbacks must retain the root's callback identity range and updated prefix");
    const auto expression = query(generation, 2);

    check(expression.contains(R"("type":"lua_expr","value":{"generation":42,"id":2})"), "expressions must expose semantic callback ids independently of Lua registry references");
  }

  void retainedCommandAndPluginDescriptions() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
          .source = R"(
          local command=telar.action.command_tab{command={'echo','quoted "中'},label='kept'}
          local plugin=telar.action.plugin{plugin='fixture',action='run'}
          return {api_version=2,client={keybindings={telar.bind({'c'},command),
            telar.bind({'p'},plugin),telar.bind({'m'},function()
              command.command[2]='changed';plugin.action='changed';return telar.action.new_tab()
            end)}}}
        )",
          .directory = {},
          .profile = {},
      };

      application::ConfigurationGeneration generation{memory, source};
      const auto command = query(generation, 0);
      const auto plugin = query(generation, 1);

      check(command.contains(R"("value":{"label":"kept","argv":["echo","quoted \"中"]})"), "command bindings must retain complete argv and label values");
      const auto parsed = telar::runtime::JsonValue::parse(plugin);
      const auto value = requiredJsonField(requiredJsonField(parsed, "action"), "value");

      check(requiredJsonField(value, "plugin").encoded() == std::to_string(telar::runtime::plugins::stableId("fixture")), "plugin descriptions must use the shared stable identifier algorithm");
      const auto before = budget.allocations();

      static_cast<void>(query(generation, 0));
      static_cast<void>(query(generation, 1));
      check(budget.allocations() == before, "repeated binding queries must not allocate through the application allocator");
      static_cast<void>(generation.invoke(generation.input().configured[2].action, {}));
      check(query(generation, 0) == command && query(generation, 1) == plugin, "callback mutation must not change retained command or plugin descriptions");
    }

    check(budget.liveBytes() == 0, "binding descriptions must release every retained allocation with their generation");
  }

  void notificationValuesAndDefinitionIndices() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
        local panels={};for i=1,18 do panels[string.format('p%02d',i)]=telar.panel{command={'true'}} end
        return {api_version=2,client={panels=panels,keybindings={
          telar.bind({'n'},telar.action.notification{title=string.rep('é',60),body='message',level='warning',duration_ms=750,pane_id=99}),
          telar.bind({'a'},telar.action.open_panel('p02')),
          telar.bind({'b'},telar.action.open_panel('p18'))}}}
      )",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};
    const auto encoded = query(generation, 0);
    const auto value = requiredJsonField(requiredJsonField(telar::runtime::JsonValue::parse(encoded), "action"), "value");

    check(requiredJsonField(value, "level").equals("warning") && requiredJsonField(value, "duration_ms").encoded() == "750", "notification descriptions must preserve severity and duration");
    check(requiredJsonField(value, "target").encoded() == R"({"pane":99})", "notification targets must retain the original tagged id shape");
    telar::ds::String<telar::ConcurrentMemory> title{memory};

    requiredJsonField(value, "title").string(title);
    check(title.size() == telar::max_notification_title_bytes, "notification fitting must preserve complete UTF-8 at the wire's title bound");
    check(query(generation, 1).contains(R"("type":"open_panel","value":1)"), "named definitions must expose their stable sorted indices");
    check(query(generation, 2).contains(R"("type":"open_panel","value":255)"), "names dropped at the definition limit must preserve the original inert index");
  }

  void byteArgumentsRemainQueryable() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = "return {api_version=2,client={keybindings={telar.bind({'x'},telar.action.command_tab{command={'echo',string.char(255)}})}}}",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};

    check(query(generation, 0).contains(R"("argv":["echo",[255]])"), "non-UTF-8 command bytes must retain their numeric-array representation");
  }

  void commandLabelsFollowPosixPaths() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
        return {api_version=2,client={keybindings={
          telar.bind({'a'},telar.action.command_tab{command={'/usr/bin/echo///'}}),
          telar.bind({'b'},telar.action.command_tab{command={'/'}}),
          telar.bind({'c'},telar.action.command_tab{command={'a'..string.char(92)..'b'}}),
          telar.bind({'d'},telar.action.command_tab{command={'echo'},label=string.char(255)})}}}
      )",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};

    check(query(generation, 0).contains(R"("label":"echo")"), "implicit labels must ignore trailing POSIX separators");
    check(query(generation, 1).contains(R"("label":"")"), "a POSIX root has no basename");
    check(query(generation, 2).contains(R"("label":"a\\b")"), "backslashes must remain literal POSIX filename bytes");
    check(query(generation, 3).contains(R"("label":[255])"), "configured labels must preserve invalid UTF-8 as byte arrays");
  }

  void boundedRepliesAndSkippedActions() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
        local too_many={};for i=1,33 do too_many[i]='x' end
        return {api_version=2,client={keybindings={telar.bind({'a'},telar.action.command_tab{command=too_many}),
          telar.bind({'b'},telar.action.command_tab{command={string.rep(string.char(92),4096)}}),
          telar.bind({'c'},telar.action.new_tab())}}}
      )",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};

    check(generation.input().length == 2, "actions past their argument limit must be omitted without leaving query holes");
    bool oversized = false;

    try {
      static_cast<void>(query(generation, 0));
    } catch (const std::length_error& error) {
      oversized = std::string_view{error.what()} == "WriteFailed";
    }

    check(oversized && query(generation, 1).contains(R"("type":"new_tab","value":null)"), "an oversized JSON action must preserve its valid snapshot and other bindings");
    bool missing = false;

    try {
      static_cast<void>(query(generation, generation.input().length));
    } catch (const std::runtime_error& error) {
      missing = std::string_view{error.what()} == "BindingNotFound";
    }

    check(missing, "queries outside configured bindings must fail instead of exposing merged builtin defaults");
  }

  void paletteIsNamedAction() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
        return {api_version=2,client={keybindings={telar.bind_global({'cmd+p'},'palette'),
          telar.bind({'a'},telar.action.palette())}}}
      )",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};

    check(query(generation, 0).contains(R"("type":"palette","value":null)") && query(generation, 1).contains(R"("type":"palette","value":null)"), "the whole palette must be bindable by its name and by its action function");
  }

  const telar::testing::Case case_configured_order_and_callback_references{"binding_query.configured_order_and_callback_references", configuredOrderAndCallbackReferences};
  const telar::testing::Case case_retained_command_and_plugin_descriptions{"binding_query.retained_command_and_plugin_descriptions", retainedCommandAndPluginDescriptions};
  const telar::testing::Case case_notification_values_and_definition_indices{"binding_query.notification_values_and_definition_indices", notificationValuesAndDefinitionIndices};
  const telar::testing::Case case_bounded_replies_and_skipped_actions{"binding_query.bounded_replies_and_skipped_actions", boundedRepliesAndSkippedActions};
  const telar::testing::Case case_byte_arguments_remain_queryable{"binding_query.byte_arguments_remain_queryable", byteArgumentsRemainQueryable};
  const telar::testing::Case case_command_labels_follow_posix_paths{"binding_query.command_labels_follow_posix_paths", commandLabelsFollowPosixPaths};
  const telar::testing::Case case_palette_is_named_action{"binding_query.palette_is_named_action", paletteIsNamedAction};

}
