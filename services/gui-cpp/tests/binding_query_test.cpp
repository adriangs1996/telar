#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>
#include <optional>
#include <string_view>
#include <utility>
#include <bit>
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <charconv>
#include <cmath>
#include <concepts>
#include <cstring>
#include <functional>
#include <limits>
#include <system_error>
#include <type_traits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include <cstdio>

#include "telar_base/text/utf8.hpp"
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <initializer_list>
#include <string>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "gui_config_bootstrap.hpp"

#include <limits.h>
#include <sys/stat.h>
#include "telar_config/graphics/limits.hpp"
#include <arpa/inet.h>
#include "telar_config/terminal/control/policy.hpp"
#include <format>
#include <ghostty/vt/unicode.h>
#include <exception>
#include <iostream>

#include "core/memory.hpp"

import telar.gui.tests.json_fixture;
import telar.gui.config.plugin_query;
import telar.gui.config.generation;
import telar.gui.config.gui_query;
import telar.gui.input.copy_pointer;
import telar.base.text;
import telar.plugins;



namespace {

using namespace telar::gui;
using telar::gui::test::requiredJsonField;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <Allocator Memory>
std::string query(const ConfigurationGeneration<Memory> &generation, std::size_t index) {
  std::array<char, ConfigurationQuery::capacity> output{};

  return std::string{BindingQuery::write(generation.input(), index, generation.actionDescriptions(), generation.commandTabs(), output)};
}

void configuredOrderAndCallbackReferences() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
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
  const ConfigurationGeneration generation{memory, source};
  const auto first = query(generation, 0);
  require(first.contains(R"("index":0,"prefixed":false)") && first.contains(R"("action":{"type":"select_tab","value":255})"), "binding queries must use configured order and zero-based semantic indices");
  const auto callback = query(generation, 1);
  require(callback.contains(R"("bytes":"中\u0000","len":3)") && callback.contains(R"("type":"lua_callback","value":{"generation":42,"id":1})"), "profile callbacks must retain the root's callback identity range and updated prefix");
  const auto expression = query(generation, 2);
  require(expression.contains(R"("type":"lua_expr","value":{"generation":42,"id":2})"), "expressions must expose semantic callback ids independently of Lua registry references");
}

void retainedCommandAndPluginDescriptions() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
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
    ConfigurationGeneration generation{memory, source};
    const auto command = query(generation, 0);
    const auto plugin = query(generation, 1);
    require(command.contains(R"("value":{"label":"kept","argv":["echo","quoted \"中"]})"), "command bindings must retain complete argv and label values");
    const auto parsed = telar::runtime::JsonValue::parse(plugin);
    const auto value = requiredJsonField(requiredJsonField(parsed, "action"), "value");
    require(requiredJsonField(value, "plugin").encoded() == std::to_string(telar::runtime::plugins::stableId("fixture")), "plugin descriptions must use the shared stable identifier algorithm");
    const auto before = memory.allocations();
    static_cast<void>(query(generation, 0));
    static_cast<void>(query(generation, 1));
    require(memory.allocations() == before, "repeated binding queries must not allocate through the application allocator");
    static_cast<void>(generation.invoke(generation.input().configured[2].action, {}));
    require(query(generation, 0) == command && query(generation, 1) == plugin, "callback mutation must not change retained command or plugin descriptions");
  }

  require(memory.liveBytes() == 0, "binding descriptions must release every retained allocation with their generation");
}

void notificationValuesAndDefinitionIndices() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
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
  const ConfigurationGeneration generation{memory, source};
  const auto encoded = query(generation, 0);
  const auto value = requiredJsonField(requiredJsonField(telar::runtime::JsonValue::parse(encoded), "action"), "value");
  require(requiredJsonField(value, "level").equals("warning") && requiredJsonField(value, "duration_ms").encoded() == "750", "notification descriptions must preserve severity and duration");
  require(requiredJsonField(value, "target").encoded() == R"({"pane":99})", "notification targets must retain the original tagged id shape");
  String<SystemAllocator> title{AllocatorRef<char, SystemAllocator>{memory}};
  requiredJsonField(value, "title").string(title);
  require(title.size() == telar::max_notification_title_bytes, "notification fitting must preserve complete UTF-8 at the wire's title bound");
  require(query(generation, 1).contains(R"("type":"open_panel","value":1)"), "named definitions must expose their stable sorted indices");
  require(query(generation, 2).contains(R"("type":"open_panel","value":255)"), "names dropped at the definition limit must preserve the original inert index");
}

void byteArgumentsRemainQueryable() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
      .source = "return {api_version=2,client={keybindings={telar.bind({'x'},telar.action.command_tab{command={'echo',string.char(255)}})}}}",
      .directory = {},
      .profile = {},
  };
  const ConfigurationGeneration generation{memory, source};
  require(query(generation, 0).contains(R"("argv":["echo",[255]])"), "non-UTF-8 command bytes must retain their numeric-array representation");
}

void commandLabelsFollowPosixPaths() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
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
  const ConfigurationGeneration generation{memory, source};
  require(query(generation, 0).contains(R"("label":"echo")"), "implicit labels must ignore trailing POSIX separators");
  require(query(generation, 1).contains(R"("label":"")"), "a POSIX root has no basename");
  require(query(generation, 2).contains(R"("label":"a\\b")"), "backslashes must remain literal POSIX filename bytes");
  require(query(generation, 3).contains(R"("label":[255])"), "configured labels must preserve invalid UTF-8 as byte arrays");
}

void boundedRepliesAndSkippedActions() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
      .source = R"(
        local too_many={};for i=1,33 do too_many[i]='x' end
        return {api_version=2,client={keybindings={telar.bind({'a'},telar.action.command_tab{command=too_many}),
          telar.bind({'b'},telar.action.command_tab{command={string.rep(string.char(92),4096)}}),
          telar.bind({'c'},telar.action.new_tab())}}}
      )",
      .directory = {},
      .profile = {},
  };
  const ConfigurationGeneration generation{memory, source};
  require(generation.input().length == 2, "actions past their argument limit must be omitted without leaving query holes");
  bool oversized = false;
  try {
    static_cast<void>(query(generation, 0));
  } catch (const std::length_error &error) {
    oversized = std::string_view{error.what()} == "WriteFailed";
  }

  require(oversized && query(generation, 1).contains(R"("type":"new_tab","value":null)"), "an oversized JSON action must preserve its valid snapshot and other bindings");
  bool missing = false;
  try {
    static_cast<void>(query(generation, generation.input().length));
  } catch (const std::runtime_error &error) {
    missing = std::string_view{error.what()} == "BindingNotFound";
  }

  require(missing, "queries outside configured bindings must fail instead of exposing merged builtin defaults");
}

}

int main() {
  try {
    configuredOrderAndCallbackReferences();
    retainedCommandAndPluginDescriptions();
    notificationValuesAndDefinitionIndices();
    boundedRepliesAndSkippedActions();
    byteArgumentsRemainQueryable();
    commandLabelsFollowPosixPaths();
    std::puts("gui-binding-query: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-binding-query: " << error.what() << '\n';

    return 1;
  }
}
