#include "config/callback.hpp"
#include "config/client_query.hpp"
#include "config/generation.hpp"
#include "config/gui_query.hpp"
#include "config/input_query.hpp"
#include "config/query.hpp"
#include "config/runtime_query.hpp"
#include "core/configuration.hpp"
#include "core/json_writer.hpp"
#include "core/memory.hpp"
#include "input/action.hpp"
#include "json_fixture.hpp"
#include "telar_base/text/json.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <limits>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using telar::gui::test::requiredJsonField;

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void nestedJsonValues(JsonWriter &writer) {
  writer.array([](JsonWriter &array) {
    array.element(nullptr);
    array.element([](JsonWriter &value) {
      value.object([](JsonWriter &object) {
        constexpr auto text = std::to_array("\"\\\n\0中");
        object.member("escaped", std::string_view{text.data(), text.size() - 1});
      });
    });
  });
}

void jsonValuesAndNestedContainers() {
  constexpr std::size_t capacity = 512;
  std::array<char, capacity> storage{};
  JsonWriter writer{storage};
  writer.object([](JsonWriter &object) {
    object.member("literal", "value");
    object.member("boolean", false);
    object.member("empty", std::optional<std::string_view>{});
    object.member("number", std::numeric_limits<std::uint64_t>::max());
    object.member("nested", nestedJsonValues);
    object.member("after", true);
  });

  const auto parsed = telar::runtime::JsonValue::parse(writer.view());
  require(requiredJsonField(parsed, "literal").equals("value"), "string literals must remain strings rather than converting to boolean");
  require(requiredJsonField(parsed, "boolean").encoded() == "false" && requiredJsonField(parsed, "after").encoded() == "true", "nested JSON containers must preserve parent separators and booleans");
  require(requiredJsonField(parsed, "empty").encoded() == "null", "absent optional values must remain JSON null");
  require(requiredJsonField(parsed, "number").encoded() == "18446744073709551615", "unsigned values must preserve every integer bit");
  require(writer.view().contains("\\u0000") && writer.view().contains("\\n"), "JSON strings must preserve the original short escapes without truncating embedded controls");
}

void jsonCapacityGuards() {
  constexpr std::string_view expected = R"({"value":"text"})";
  constexpr char guard = 'g';
  for (std::size_t capacity = 0; capacity <= expected.size(); ++capacity) {
    std::array<char, expected.size() + 1> storage{};
    storage.fill(guard);
    JsonWriter writer{std::span{storage}.first(capacity)};
    bool failed = false;
    try {
      writer.object([](JsonWriter &object) {
        object.member("value", "text");
      });
    } catch (const std::length_error &error) {
      failed = std::string_view{error.what()} == "WriteFailed";
    }

    require(failed == (capacity < expected.size()), "a bounded writer must reject every undersized destination");
    require(storage[capacity] == guard, "JSON overflow must preserve the destination guard byte");
    if (!failed) {
      require(writer.view() == expected, "the exact output capacity must succeed without a trailing terminator");
    }
  }
}

void retainedRuntimeProfileAndCallbackMutation() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = R"(
          local runtime = {history={path='history.db',output='bounded'}, session={persist=false},
            proxy={enabled=true,intercept_hosts={'Z.test','a.test','z.test'},capture={enabled=true}},
            graphics={pane_mib=8,global_mib=16}}
          return {api_version=2,runtime=runtime,client={keybindings={telar.bind({'s'},function()
            runtime.history.path='changed.db'
            return telar.action.new_tab()
          end)}},profiles={selected={runtime={graphics={global_mib=32},session={path='session.db'}}}}}
        )",
        .directory = {},
        .profile = "selected",
    };
    ConfigurationGeneration generation{memory, source};
    std::array<char, ConfigurationQuery::capacity> output{};
    const auto before = memory.allocations();
    const auto encoded = RuntimeQuery::write(generation.runtimeValues(), output);
    require(memory.allocations() == before, "querying adopted runtime values must not allocate through the injected allocator");
    const auto parsed = telar::runtime::JsonValue::parse(encoded);
    require(requiredJsonField(parsed, "history_path").equals("history.db"), "profile overlays must preserve an inherited history path");
    require(requiredJsonField(parsed, "session_path").equals("session.db") && !requiredJsonField(parsed, "session_persist").boolean(), "profile paths must override independently of inherited session flags");
    require(requiredJsonField(parsed, "graphics_pane_bytes").encoded() == "8388608" && requiredJsonField(parsed, "graphics_global_bytes").encoded() == "33554432", "runtime graphics queries must report effective byte limits");
    require(requiredJsonField(parsed, "proxy_intercept_hosts").encoded() == R"(["a.test","z.test"])", "proxy queries must retain normalized, sorted and deduplicated host patterns");
    const auto &binding = generation.input().configured.front();
    require(generation.invoke(binding.action, {}).actions.front().kind == BindingActionKind::new_tab, "the mutation fixture must execute its retained callback");
    const auto unchanged = telar::runtime::JsonValue::parse(RuntimeQuery::write(generation.runtimeValues(), output));
    require(requiredJsonField(unchanged, "history_path").equals("history.db"), "queries must read adopted values rather than mutable Lua tables");
  }

  require(memory.liveBytes() == 0, "runtime query snapshots must release all injected storage with their generation");
}

void runtimeQueryBoundsAndGenerationFailure() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{.source = "return {api_version=2}", .directory = {}, .profile = {}};
    const ConfigurationGeneration generation{memory, source};
    std::array<char, 1> tiny{};
    bool failed = false;
    try {
      static_cast<void>(RuntimeQuery::write(generation.runtimeValues(), tiny));
    } catch (const std::length_error &error) {
      failed = std::string_view{error.what()} == "WriteFailed";
    }

    require(failed, "an oversized section must fail instead of returning truncated JSON");
    std::array<char, ConfigurationQuery::capacity> output{};
    const auto parsed = telar::runtime::JsonValue::parse(RuntimeQuery::write(generation.runtimeValues(), output));
    require(requiredJsonField(parsed, "history_path").encoded() == "null" && requiredJsonField(parsed, "session_path").encoded() == "null", "unconfigured paths must be JSON null");
    require(requiredJsonField(parsed, "proxy_intercept_hosts").encoded() == "[]", "default proxy interception must be empty");
  }

  require(memory.liveBytes() == 0, "default snapshot ownership must be balanced");
  bool rejected = false;
  try {
    const ConfigurationGeneration generation{memory, ConfigurationSourceText{.source = "return {api_version=2,runtime={graphics={pane_mib=0}}}", .directory = {}, .profile = {}}};
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected && memory.liveBytes() == 0, "failed runtime preparation must release its partially constructed generation");
}

void oversizedRuntimeSectionDoesNotRejectConfiguration() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = "local p=string.rep(string.char(92),1024); return {api_version=2,runtime={history={path=p},session={path=p},proxy={ca_dir=p}}}",
        .directory = {},
        .profile = {},
    };
    const ConfigurationGeneration generation{memory, source};
    std::array<char, ConfigurationQuery::capacity> output{};
    bool rejected = false;
    try {
      static_cast<void>(RuntimeQuery::write(generation.runtimeValues(), output));
    } catch (const std::length_error &error) {
      rejected = std::string_view{error.what()} == "WriteFailed";
    }

    require(rejected && !generation.runtimeValues().history_path.empty(), "a valid snapshot must survive a section that exceeds the command response capacity");
  }

  require(memory.liveBytes() == 0, "oversized query results must not retain configuration storage after teardown");
}

void configuredAgentsRetainTheCompleteProviderRange() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = "local agents={};for i=1,27 do agents[i]={name='fixture-'..i,icon='a'} end;return {api_version=2,runtime={agents=agents}}",
        .directory = {},
        .profile = {},
    };
    const ConfigurationGeneration generation{memory, source};
    const auto agents = generation.runtimeValues().manifests.entries();
    require(agents.size() == telar::max_agent_provider_index, "the retained snapshot must include every builtin and custom agent slot");
    require(agents.back().provider == telar::AgentProvider::last_custom, "custom agent identifiers must span the complete wire range");
  }

  require(memory.liveBytes() == 0, "full agent snapshots must release their retained state");
  bool rejected = false;
  try {
    const ConfigurationGeneration generation{memory, ConfigurationSourceText{.source = "return {api_version=2,runtime={agents={{name='wide-icon',icon='中'}}}}", .directory = {}, .profile = {}}};
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected && memory.liveBytes() == 0, "configured icons must use the runtime's exact Unicode cell-width validation");
}

void shortEscapesPreserveTheOriginalResponseCapacity() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
      .source = "local p=string.rep(string.char(10),512); return {api_version=2,runtime={history={path=p},session={path=p},proxy={ca_dir=p}}}",
      .directory = {},
      .profile = {},
  };
  const ConfigurationGeneration generation{memory, source};
  std::array<char, ConfigurationQuery::capacity> output{};
  const auto encoded = RuntimeQuery::write(generation.runtimeValues(), output);
  const auto parsed = telar::runtime::JsonValue::parse(encoded);
  String<SystemAllocator> decoded{AllocatorRef<char, SystemAllocator>{memory}};
  requiredJsonField(parsed, "history_path").string(decoded);
  constexpr std::size_t path_length = 512;
  require(decoded.size() == path_length && std::string_view{decoded}.find_first_not_of('\n') == std::string_view::npos, "a control-dense section that fits the original response buffer must preserve its complete paths");
}

void runtimeSnapshotAllocationFailureReleasesTheVm() {
  SystemAllocator system;
  constexpr std::size_t insufficient_snapshot_budget = std::size_t{128} * 1024;
  BudgetAllocator memory{system, insufficient_snapshot_budget};
  bool rejected = false;
  try {
    const ConfigurationGeneration generation{memory, ConfigurationSourceText{.source = "return {api_version=2}", .directory = {}, .profile = {}}};
  } catch (const std::bad_alloc &) {
    rejected = true;
  }

  require(rejected && memory.liveBytes() == 0, "a failed typed snapshot allocation must release the Lua VM constructed before it");
}

void adoptedGuiAndInputQueries() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = R"(
          local gui={font={family='Fixture "中',style='Italic',size=15.1,line_height=1.1,letter_spacing=-0.5},
            window={padding={x=-0.0,y=2.5}},cursor={style='hollow',blink=false},chrome={scale=1.25}}
          return {api_version=2,gui=gui,client={prefix='ctrl+b',input={sequence_timeout_ms=250},
            keybindings={telar.bind({'s'},function() gui.font.size=42; return telar.action.new_tab() end),
              telar.bind_global({'é'},telar.action.toggle_sidebar())}},
            profiles={selected={gui={font={size=18.25},sidebar={width=300}},client={prefix='alt+中'}}}}
        )",
        .directory = {},
        .profile = "selected",
    };
    ConfigurationGeneration generation{memory, source};
    std::array<char, ConfigurationQuery::capacity> output{};
    const auto allocations = memory.allocations();
    const auto gui = telar::runtime::JsonValue::parse(GuiQuery::write(generation.configuration(), output, false));
    const auto font = requiredJsonField(gui, "font");
    require(requiredJsonField(font, "size").encoded() == "18.25", "GUI queries must retain the selected profile's font size");
    require(requiredJsonField(font, "line_height").encoded() == "1.100000023841858", "f32 preferences must preserve Zig's f64 JSON promotion");
    require(requiredJsonField(requiredJsonField(gui, "window"), "titlebar").encoded() == "false", "native defaults must be supplied without importing a native API into the query");
    const auto cursor = requiredJsonField(gui, "cursor");
    require(requiredJsonField(cursor, "style").equals("hollow") && !requiredJsonField(cursor, "blink").boolean(), "GUI cursor queries must preserve style and blinking preferences");
    const auto input = telar::runtime::JsonValue::parse(InputQuery::write(generation.input(), output));
    require(requiredJsonField(input, "binding_count").encoded() == "2", "input queries must count configured bindings independently of builtin defaults");
    require(requiredJsonField(input, "sequence_timeout_ns").encoded() == "250000000", "input queries must preserve inherited sequence timing");
    require(requiredJsonField(requiredJsonField(input, "prefix"), "code").encoded() == R"({"char":{"bytes":"中\u0000","len":3}})", "a profile prefix must preserve its UTF-8 bytes and zero-filled suffix");
    require(memory.allocations() == allocations, "GUI and input queries must not allocate from the application allocator");
    static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
    const auto unchanged = telar::runtime::JsonValue::parse(GuiQuery::write(generation.configuration(), output, true));
    require(requiredJsonField(requiredJsonField(unchanged, "font"), "size").encoded() == "18.25", "callback mutation must not alter the adopted GUI snapshot");
    require(requiredJsonField(requiredJsonField(unchanged, "window"), "titlebar").encoded() == "true", "the same snapshot must accept either platform's titlebar default");
  }

  require(memory.liveBytes() == 0, "GUI and input snapshots must release every injected allocation");
}

void floatingPointBoundsAndNamedPrefixes() {
  constexpr std::string_view expected = R"({"value":1.100000023841858})";
  for (std::size_t capacity = 0; capacity <= expected.size(); ++capacity) {
    std::array<char, expected.size() + 1> output{};
    constexpr char guard = 'g';
    output.fill(guard);
    JsonWriter writer{std::span{output}.first(capacity)};
    bool rejected = false;
    try {
      writer.object([](JsonWriter &object) {
        constexpr float fractional_preference = 1.1F;
        object.member("value", fractional_preference);
      });
    } catch (const std::length_error &) {
      rejected = true;
    }

    require(rejected == (capacity < expected.size()) && output[capacity] == guard, "floating point formatting must honor exact caller capacity without overwriting its guard");
    if (!rejected) {
      require(writer.view() == expected, "floating point JSON must use the original promoted decimal representation");
    }
  }

  InputConfiguration input;
  input.prefix = {.key = KeyChord::Key::back_tab};
  std::array<char, ConfigurationQuery::capacity> output{};
  const auto parsed = telar::runtime::JsonValue::parse(InputQuery::write(input, output));
  require(requiredJsonField(requiredJsonField(parsed, "prefix"), "code").encoded() == R"({"back_tab":{}})", "named key union payloads must remain empty objects rather than null");
}

void clientPoliciesAndLiveViewRemainIndependent() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = R"(
          local client={sound={enabled=false,ready=false},notifications={delivery='system'},
            history={show_agent_commands=true,enter='run',match='fts'},window_title='{tab}',
            sidebar={visible=false},pane_gaps=false}
          client.keybindings={telar.bind({'m'},function()
            client.sound.enabled=true;client.notifications.delivery='telar';client.history.match='fuzzy'
            return telar.action.new_tab()
          end)}
          return {api_version=2,client=client,profiles={chosen={client={
            sound={ready=true},notifications={delivery='terminal'},history={enter='paste'}}}}}
        )",
        .directory = {},
        .profile = "chosen",
        .generation = std::numeric_limits<std::uint64_t>::max(),
    };
    ConfigurationGeneration generation{memory, source};
    const ClientQueryContext context{
        .source = "relative/config.lua",
        .profile = "chosen",
        .generation = generation.number(),
        .view = {.sidebar_visible = true, .sidebar_width = 61, .workspace_list_collapsed = true, .pane_gaps = true, .window_title = "{workspace}"},
    };
    std::array<char, ConfigurationQuery::capacity> output{};
    const auto allocations = memory.allocations();
    const std::string before{ClientQuery::write(generation.configuration(), context, output)};
    const auto parsed = telar::runtime::JsonValue::parse(before);
    require(requiredJsonField(parsed, "generation").encoded() == "18446744073709551615", "client queries must preserve the adopted generation's complete identifier");
    require(requiredJsonField(parsed, "sidebar_visible").boolean() && requiredJsonField(parsed, "sidebar_width").encoded() == "61", "client queries must use live visibility and semantic columns independently of configured pixels");
    require(requiredJsonField(parsed, "workspace_list_collapsed").boolean() && requiredJsonField(parsed, "pane_gaps").boolean() && requiredJsonField(parsed, "window_title").equals("{workspace}"), "client queries must expose the supplied live view rather than overwrite it with snapshot defaults");
    require(requiredJsonField(parsed, "sound").encoded() == R"({"enabled":false,"ready":true,"needs_input":true})", "sound fields must inherit independently across selected profiles");
    require(requiredJsonField(parsed, "notification_delivery").equals("system"), "the retired terminal delivery alias must preserve inherited delivery");
    require(!requiredJsonField(parsed, "history_enter_runs").boolean() && requiredJsonField(parsed, "history_match_fts").boolean(), "history query flags must retain independent profile overrides");
    require(memory.allocations() == allocations, "client serialization must not allocate through the application allocator");
    static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
    require(ClientQuery::write(generation.configuration(), context, output) == before, "Lua mutation must not change adopted client policies");
  }

  require(memory.liveBytes() == 0, "client policy snapshots must release their generation's allocations");
}

void clientMetadataAndResponseBounds() {
  const Configuration configuration;
  ClientQueryContext context;
  std::array<char, ConfigurationQuery::capacity> output{};
  const auto defaults = telar::runtime::JsonValue::parse(ClientQuery::write(configuration, context, output));
  require(requiredJsonField(defaults, "source").encoded() == "null", "an absent source must remain null");
  require(requiredJsonField(defaults, "sound").encoded() == R"({"enabled":true,"ready":true,"needs_input":true})", "sound defaults must match the original policy");
  constexpr auto source = std::to_array<char>({'x', static_cast<char>(0xff)});
  context.source = std::string_view{source.data(), source.size()};
  context.profile = std::string_view{};
  const std::string complete{ClientQuery::write(configuration, context, output)};
  require(complete.contains(R"("source":[120,255],"profile":"")"), "optional byte metadata must distinguish absence, empty text and invalid UTF-8");
  constexpr char guard = 'g';
  for (const auto capacity : {complete.size() - 1, complete.size(), complete.size() + 1}) {
    output.fill(guard);
    bool failed = false;
    try {
      require(ClientQuery::write(configuration, context, std::span{output}.first(capacity)) == complete, "successful client replies must preserve every byte");
    } catch (const std::length_error &error) {
      failed = std::string_view{error.what()} == "WriteFailed";
    }

    require(failed == (capacity < complete.size()) && output[capacity] == guard, "client replies must honor exact capacity without overwriting its guard");
  }
}

void unselectedProfilesAreValidated() {
  constexpr auto invalid_configurations = std::to_array<std::string_view>({
      "return {api_version=2,profiles={unused={runtime={graphics={pane_mib=0}}}}}",
      "return {api_version=2,profiles={unused={client={unknown=true}}}}",
      "return {api_version=2,profiles={['invalid name']={}}}",
      "return {api_version=2,profiles={unused={gui={font={size=0}}}}}",
      "return {api_version=2,profiles={unused={theme={unknown=true}}}}",
  });
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  for (const auto source : invalid_configurations) {
    bool rejected = false;
    try {
      const ConfigurationGeneration generation{memory, ConfigurationSourceText{.source = source, .directory = {}, .profile = {}}};
    } catch (const std::exception &) {
      rejected = true;
    }

    require(rejected && memory.liveBytes() == 0, "an invalid unselected profile must reject the generation and release partial construction");
  }

  const ConfigurationSourceText source{
      .source = "return {api_version=2,runtime={history={path='root.db'}},profiles={unused={runtime={history={path='unused.db'}}}}}",
      .directory = {},
      .profile = {},
  };
  const ConfigurationGeneration generation{memory, source};
  require(generation.runtimeValues().history_path == "root.db", "validation of an unselected profile must not adopt its runtime values");
}

}

int main() {
  try {
    jsonValuesAndNestedContainers();
    jsonCapacityGuards();
    retainedRuntimeProfileAndCallbackMutation();
    runtimeQueryBoundsAndGenerationFailure();
    oversizedRuntimeSectionDoesNotRejectConfiguration();
    configuredAgentsRetainTheCompleteProviderRange();
    shortEscapesPreserveTheOriginalResponseCapacity();
    runtimeSnapshotAllocationFailureReleasesTheVm();
    adoptedGuiAndInputQueries();
    floatingPointBoundsAndNamedPrefixes();
    unselectedProfilesAreValidated();
    clientPoliciesAndLiveViewRemainIndependent();
    clientMetadataAndResponseBounds();
    std::puts("gui-config-query: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-config-query: " << error.what() << '\n';

    return 1;
  }
}
