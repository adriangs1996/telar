#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>

#include <climits>
#include <exception>
#include <new>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.tests.json_fixture;
import telar.gui.features.configuration;
import telar.gui.application;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.features.status_bar;
import telar.base.text.json;
import telar.gui.foundation.keys;
import telar.base.ds;

namespace {

  using telar::gui::test::requiredJsonField;
  using telar::testing::check;

  using namespace telar::gui;

  using namespace telar::gui::features::configuration;

  void nestedJsonValues(JsonWriter& writer) {
    writer.array([](JsonWriter& array) {
      array.element(nullptr);
      array.element([](JsonWriter& value) {
        value.object([](JsonWriter& object) {
          constexpr auto text = telar::ds::toArray("\"\\\n\0中");

          object.member("escaped", std::string_view{text.data(), text.size() - 1});
        });
      });
    });
  }

  void jsonValuesAndNestedContainers() {
    constexpr std::size_t capacity = 512;
    telar::ds::Array<char, capacity> storage{};
    JsonWriter writer{storage.viewMut()};

    writer.object([](JsonWriter& object) {
      object.member("literal", "value");
      object.member("boolean", false);
      object.member("empty", telar::ds::Option<std::string_view>{});
      object.member("number", std::numeric_limits<std::uint64_t>::max());
      object.member("nested", nestedJsonValues);
      object.member("after", true);
    });

    const auto parsed = telar::runtime::JsonValue::parse(writer.view());

    check(requiredJsonField(parsed, "literal").equals("value"), "string literals must remain strings rather than converting to boolean");
    check(requiredJsonField(parsed, "boolean").encoded() == "false" && requiredJsonField(parsed, "after").encoded() == "true", "nested JSON containers must preserve parent separators and booleans");
    check(requiredJsonField(parsed, "empty").encoded() == "null", "absent optional values must remain JSON null");
    check(requiredJsonField(parsed, "number").encoded() == "18446744073709551615", "unsigned values must preserve every integer bit");
    check(writer.view().contains("\\u0000") && writer.view().contains("\\n"), "JSON strings must preserve the original short escapes without truncating embedded controls");
  }

  void jsonCapacityGuards() {
    constexpr std::string_view expected = R"({"value":"text"})";
    constexpr char guard = 'g';

    for (std::size_t capacity = 0; capacity <= expected.size(); ++capacity) {
      telar::ds::Array<char, expected.size() + 1> storage{};

      storage.fill(guard);
      JsonWriter writer{storage.viewMut().first(capacity)};
      bool failed = false;

      try {
        writer.object([](JsonWriter& object) {
          object.member("value", "text");
        });
      } catch (const std::length_error& error) {
        failed = std::string_view{error.what()} == "WriteFailed";
      }

      check(failed == (capacity < expected.size()), "a bounded writer must reject every undersized destination");
      check(storage[capacity] == guard, "JSON overflow must preserve the destination guard byte");
      if (!failed) {
        check(writer.view() == expected, "the exact output capacity must succeed without a trailing terminator");
      }
    }
  }

  void retainedRuntimeProfileAndCallbackMutation() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
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

      application::ConfigurationGeneration generation{memory, source};
      telar::ds::Array<char, ConfigurationQuery::capacity> output{};
      const auto before = budget.allocations();
      const auto encoded = RuntimeQuery::write(generation.runtimeValues(), output.viewMut());

      check(budget.allocations() == before, "querying adopted runtime values must not allocate through the injected allocator");
      const auto parsed = telar::runtime::JsonValue::parse(encoded);

      check(requiredJsonField(parsed, "history_path").equals("history.db"), "profile overlays must preserve an inherited history path");
      check(requiredJsonField(parsed, "session_path").equals("session.db") && !requiredJsonField(parsed, "session_persist").boolean(), "profile paths must override independently of inherited session flags");
      check(requiredJsonField(parsed, "graphics_pane_bytes").encoded() == "8388608" && requiredJsonField(parsed, "graphics_global_bytes").encoded() == "33554432", "runtime graphics queries must report effective byte limits");
      check(requiredJsonField(parsed, "proxy_intercept_hosts").encoded() == R"(["a.test","z.test"])", "proxy queries must retain normalized, sorted and deduplicated host patterns");
      const auto& binding = generation.input().configured.front();

      check(generation.invoke(binding.action, {}).actions.front().kind == BindingActionKind::new_tab, "the mutation fixture must execute its retained callback");
      const auto unchanged = telar::runtime::JsonValue::parse(RuntimeQuery::write(generation.runtimeValues(), output.viewMut()));

      check(requiredJsonField(unchanged, "history_path").equals("history.db"), "queries must read adopted values rather than mutable Lua tables");
    }

    check(budget.liveBytes() == 0, "runtime query snapshots must release all injected storage with their generation");
  }

  void runtimeQueryBoundsAndGenerationFailure() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{.source = "return {api_version=2}", .directory = {}, .profile = {}};
      const application::ConfigurationGeneration generation{memory, source};
      telar::ds::Array<char, 1> tiny{};
      bool failed = false;

      try {
        static_cast<void>(RuntimeQuery::write(generation.runtimeValues(), tiny.viewMut()));
      } catch (const std::length_error& error) {
        failed = std::string_view{error.what()} == "WriteFailed";
      }

      check(failed, "an oversized section must fail instead of returning truncated JSON");
      telar::ds::Array<char, ConfigurationQuery::capacity> output{};
      const auto parsed = telar::runtime::JsonValue::parse(RuntimeQuery::write(generation.runtimeValues(), output.viewMut()));

      check(requiredJsonField(parsed, "history_path").encoded() == "null" && requiredJsonField(parsed, "session_path").encoded() == "null", "unconfigured paths must be JSON null");
      check(requiredJsonField(parsed, "proxy_intercept_hosts").encoded() == "[]", "default proxy interception must be empty");
    }

    check(budget.liveBytes() == 0, "default snapshot ownership must be balanced");
    bool rejected = false;

    try {
      const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = "return {api_version=2,runtime={graphics={pane_mib=0}}}", .directory = {}, .profile = {}}};
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected && budget.liveBytes() == 0, "failed runtime preparation must release its partially constructed generation");
  }

  void oversizedRuntimeSectionDoesNotRejectConfiguration() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
          .source = "local p=string.rep(string.char(92),1024); return {api_version=2,runtime={history={path=p},session={path=p},proxy={ca_dir=p}}}",
          .directory = {},
          .profile = {},
      };

      const application::ConfigurationGeneration generation{memory, source};
      telar::ds::Array<char, ConfigurationQuery::capacity> output{};
      bool rejected = false;

      try {
        static_cast<void>(RuntimeQuery::write(generation.runtimeValues(), output.viewMut()));
      } catch (const std::length_error& error) {
        rejected = std::string_view{error.what()} == "WriteFailed";
      }

      check(rejected && !generation.runtimeValues().history_path.empty(), "a valid snapshot must survive a section that exceeds the command response capacity");
    }

    check(budget.liveBytes() == 0, "oversized query results must not retain configuration storage after teardown");
  }

  void configuredAgentsRetainTheCompleteProviderRange() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
          .source = "local agents={};for i=1,27 do agents[i]={name='fixture-'..i,icon='a'} end;return {api_version=2,runtime={agents=agents}}",
          .directory = {},
          .profile = {},
      };

      const application::ConfigurationGeneration generation{memory, source};
      const auto agents = generation.runtimeValues().manifests.entries();

      check(agents.size() == telar::max_agent_provider_index, "the retained snapshot must include every builtin and custom agent slot");
      check(agents.back().provider == telar::AgentProvider::last_custom, "custom agent identifiers must span the complete wire range");
    }

    check(budget.liveBytes() == 0, "full agent snapshots must release their retained state");
    bool rejected = false;

    try {
      const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = "return {api_version=2,runtime={agents={{name='wide-icon',icon='中'}}}}", .directory = {}, .profile = {}}};
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected && budget.liveBytes() == 0, "configured icons must use the runtime's exact Unicode cell-width validation");
  }

  void shortEscapesPreserveTheOriginalResponseCapacity() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = "local p=string.rep(string.char(10),512); return {api_version=2,runtime={history={path=p},session={path=p},proxy={ca_dir=p}}}",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};
    telar::ds::Array<char, ConfigurationQuery::capacity> output{};
    const auto encoded = RuntimeQuery::write(generation.runtimeValues(), output.viewMut());
    const auto parsed = telar::runtime::JsonValue::parse(encoded);
    telar::ds::String<telar::ConcurrentMemory> decoded{memory};

    requiredJsonField(parsed, "history_path").string(decoded);
    constexpr std::size_t path_length = 512;

    check(decoded.size() == path_length && std::string_view{decoded}.find_first_not_of('\n') == std::string_view::npos, "a control-dense section that fits the original response buffer must preserve its complete paths");
  }

  void runtimeSnapshotAllocationFailureReleasesTheVm() {
    SystemAllocator system;
    constexpr std::size_t insufficient_snapshot_budget = std::size_t{128} * 1024;
    BudgetAllocator budget{system, insufficient_snapshot_budget};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    bool rejected = false;

    try {
      const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = "return {api_version=2}", .directory = {}, .profile = {}}};
    } catch (const std::bad_alloc&) {
      rejected = true;
    }

    check(rejected && budget.liveBytes() == 0, "a failed typed snapshot allocation must release the Lua VM constructed before it");
  }

  void adoptedGuiAndInputQueries() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
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

      application::ConfigurationGeneration generation{memory, source};
      telar::ds::Array<char, ConfigurationQuery::capacity> output{};
      const auto allocations = budget.allocations();
      const auto gui = telar::runtime::JsonValue::parse(GuiQuery::write(generation.configuration(), output.viewMut(), false));
      const auto font = requiredJsonField(gui, "font");

      check(requiredJsonField(font, "size").encoded() == "18.25", "GUI queries must retain the selected profile's font size");
      check(requiredJsonField(font, "line_height").encoded() == "1.100000023841858", "f32 preferences must keep their f64 JSON promotion");
      check(requiredJsonField(requiredJsonField(gui, "window"), "titlebar").encoded() == "false", "native defaults must be supplied without importing a native API into the query");
      const auto cursor = requiredJsonField(gui, "cursor");

      check(requiredJsonField(cursor, "style").equals("hollow") && !requiredJsonField(cursor, "blink").boolean(), "GUI cursor queries must preserve style and blinking preferences");
      const auto input = telar::runtime::JsonValue::parse(InputQuery::write(generation.input(), output.viewMut()));

      check(requiredJsonField(input, "binding_count").encoded() == "2", "input queries must count configured bindings independently of builtin defaults");
      check(requiredJsonField(input, "sequence_timeout_ns").encoded() == "250000000", "input queries must preserve inherited sequence timing");
      check(requiredJsonField(requiredJsonField(input, "prefix"), "code").encoded() == R"({"char":{"bytes":"中\u0000","len":3}})", "a profile prefix must preserve its UTF-8 bytes and zero-filled suffix");
      check(budget.allocations() == allocations, "GUI and input queries must not allocate from the application allocator");
      static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
      const auto unchanged = telar::runtime::JsonValue::parse(GuiQuery::write(generation.configuration(), output.viewMut(), true));

      check(requiredJsonField(requiredJsonField(unchanged, "font"), "size").encoded() == "18.25", "callback mutation must not alter the adopted GUI snapshot");
      check(requiredJsonField(requiredJsonField(unchanged, "window"), "titlebar").encoded() == "true", "the same snapshot must accept either platform's titlebar default");
    }

    check(budget.liveBytes() == 0, "GUI and input snapshots must release every injected allocation");
  }

  void floatingPointBoundsAndNamedPrefixes() {
    constexpr std::string_view expected = R"({"value":1.100000023841858})";

    for (std::size_t capacity = 0; capacity <= expected.size(); ++capacity) {
      telar::ds::Array<char, expected.size() + 1> output{};
      constexpr char guard = 'g';

      output.fill(guard);
      JsonWriter writer{output.viewMut().first(capacity)};
      bool rejected = false;

      try {
        writer.object([](JsonWriter& object) {
          constexpr float fractional_preference = 1.1F;

          object.member("value", fractional_preference);
        });
      } catch (const std::length_error&) {
        rejected = true;
      }

      check(rejected == (capacity < expected.size()) && output[capacity] == guard, "floating point formatting must honor exact caller capacity without overwriting its guard");
      if (!rejected) {
        check(writer.view() == expected, "floating point JSON must use the original promoted decimal representation");
      }
    }

    InputConfiguration input;

    input.prefix = {.key = KeyChord::Key::back_tab};
    telar::ds::Array<char, ConfigurationQuery::capacity> output{};
    const auto parsed = telar::runtime::JsonValue::parse(InputQuery::write(input, output.viewMut()));

    check(requiredJsonField(requiredJsonField(parsed, "prefix"), "code").encoded() == R"({"back_tab":{}})", "named key union payloads must remain empty objects rather than null");
  }

  void clientPoliciesAndLiveViewRemainIndependent() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
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

      application::ConfigurationGeneration generation{memory, source};
      const application::ClientQueryContext context{
          .source = "relative/config.lua",
          .profile = "chosen",
          .generation = generation.number(),
          .view = {.sidebar_visible = true, .sidebar_width = 61, .workspace_list_collapsed = true, .pane_gaps = true, .window_title = "{workspace}"},
      };

      telar::ds::Array<char, ConfigurationQuery::capacity> output{};
      const auto allocations = budget.allocations();
      const std::string before{application::ClientQuery::write(generation.configuration(), context, output.viewMut())};
      const auto parsed = telar::runtime::JsonValue::parse(before);

      check(requiredJsonField(parsed, "generation").encoded() == "18446744073709551615", "client queries must preserve the adopted generation's complete identifier");
      check(requiredJsonField(parsed, "sidebar_visible").boolean() && requiredJsonField(parsed, "sidebar_width").encoded() == "61", "client queries must use live visibility and semantic columns independently of configured pixels");
      check(requiredJsonField(parsed, "workspace_list_collapsed").boolean() && requiredJsonField(parsed, "pane_gaps").boolean() && requiredJsonField(parsed, "window_title").equals("{workspace}"), "client queries must expose the supplied live view rather than overwrite it with snapshot defaults");
      check(requiredJsonField(parsed, "sound").encoded() == R"({"enabled":false,"ready":true,"needs_input":true})", "sound fields must inherit independently across selected profiles");
      check(requiredJsonField(parsed, "notification_delivery").equals("system"), "the retired terminal delivery alias must preserve inherited delivery");
      check(!requiredJsonField(parsed, "history_enter_runs").boolean() && requiredJsonField(parsed, "history_match_fts").boolean(), "history query flags must retain independent profile overrides");
      check(budget.allocations() == allocations, "client serialization must not allocate through the application allocator");
      static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
      check(application::ClientQuery::write(generation.configuration(), context, output.viewMut()) == before, "Lua mutation must not change adopted client policies");
    }

    check(budget.liveBytes() == 0, "client policy snapshots must release their generation's allocations");
  }

  void clientMetadataAndResponseBounds() {
    const Configuration configuration;
    application::ClientQueryContext context;
    telar::ds::Array<char, ConfigurationQuery::capacity> output{};
    const auto defaults = telar::runtime::JsonValue::parse(application::ClientQuery::write(configuration, context, output.viewMut()));

    check(requiredJsonField(defaults, "source").encoded() == "null", "an absent source must remain null");
    check(requiredJsonField(defaults, "sound").encoded() == R"({"enabled":true,"ready":true,"needs_input":true})", "sound defaults must match the original policy");
    constexpr auto source = telar::ds::Array<char, 2>{'x', static_cast<char>(0xff)};

    context.source = std::string_view{source.data(), source.size()};
    context.profile = std::string_view{};
    const std::string complete{application::ClientQuery::write(configuration, context, output.viewMut())};

    check(complete.contains(R"("source":[120,255],"profile":"")"), "optional byte metadata must distinguish absence, empty text and invalid UTF-8");
    constexpr char guard = 'g';

    for (const auto capacity : {complete.size() - 1, complete.size(), complete.size() + 1}) {
      output.fill(guard);
      bool failed = false;

      try {
        check(application::ClientQuery::write(configuration, context, output.viewMut().first(capacity)) == complete, "successful client replies must preserve every byte");
      } catch (const std::length_error& error) {
        failed = std::string_view{error.what()} == "WriteFailed";
      }

      check(failed == (capacity < complete.size()) && output[capacity] == guard, "client replies must honor exact capacity without overwriting its guard");
    }
  }

  void unselectedProfilesAreValidated() {
    constexpr auto invalid_configurations = telar::ds::Array<std::string_view, 5>{
        "return {api_version=2,profiles={unused={runtime={graphics={pane_mib=0}}}}}",
        "return {api_version=2,profiles={unused={client={unknown=true}}}}",
        "return {api_version=2,profiles={['invalid name']={}}}",
        "return {api_version=2,profiles={unused={gui={font={size=0}}}}}",
        "return {api_version=2,profiles={unused={theme={unknown=true}}}}",
    };

    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    for (const auto source : invalid_configurations) {
      bool rejected = false;

      try {
        const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = source, .directory = {}, .profile = {}}};
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected && budget.liveBytes() == 0, "an invalid unselected profile must reject the generation and release partial construction");
    }

    const application::ConfigurationSourceText source{
        .source = "return {api_version=2,runtime={history={path='root.db'}},profiles={unused={runtime={history={path='unused.db'}}}}}",
        .directory = {},
        .profile = {},
    };

    const application::ConfigurationGeneration generation{memory, source};

    check(generation.runtimeValues().history_path == "root.db", "validation of an unselected profile must not adopt its runtime values");
  }

  const telar::testing::Case case_json_values_and_nested_containers{"configuration_query.json_values_and_nested_containers", jsonValuesAndNestedContainers};
  const telar::testing::Case case_json_capacity_guards{"configuration_query.json_capacity_guards", jsonCapacityGuards};
  const telar::testing::Case case_retained_runtime_profile_and_callback_mutation{"configuration_query.retained_runtime_profile_and_callback_mutation", retainedRuntimeProfileAndCallbackMutation};
  const telar::testing::Case case_runtime_query_bounds_and_generation_failure{"configuration_query.runtime_query_bounds_and_generation_failure", runtimeQueryBoundsAndGenerationFailure};
  const telar::testing::Case case_oversized_runtime_section_does_not_reject_configuration{"configuration_query.oversized_runtime_section_does_not_reject_configuration", oversizedRuntimeSectionDoesNotRejectConfiguration};
  const telar::testing::Case case_configured_agents_retain_the_complete_provider_range{"configuration_query.configured_agents_retain_the_complete_provider_range", configuredAgentsRetainTheCompleteProviderRange};
  const telar::testing::Case case_short_escapes_preserve_the_original_response_capacity{"configuration_query.short_escapes_preserve_the_original_response_capacity", shortEscapesPreserveTheOriginalResponseCapacity};
  const telar::testing::Case case_runtime_snapshot_allocation_failure_releases_the_vm{"configuration_query.runtime_snapshot_allocation_failure_releases_the_vm", runtimeSnapshotAllocationFailureReleasesTheVm};
  const telar::testing::Case case_adopted_gui_and_input_queries{"configuration_query.adopted_gui_and_input_queries", adoptedGuiAndInputQueries};
  const telar::testing::Case case_floating_point_bounds_and_named_prefixes{"configuration_query.floating_point_bounds_and_named_prefixes", floatingPointBoundsAndNamedPrefixes};
  const telar::testing::Case case_unselected_profiles_are_validated{"configuration_query.unselected_profiles_are_validated", unselectedProfilesAreValidated};
  const telar::testing::Case case_client_policies_and_live_view_remain_independent{"configuration_query.client_policies_and_live_view_remain_independent", clientPoliciesAndLiveViewRemainIndependent};
  const telar::testing::Case case_client_metadata_and_response_bounds{"configuration_query.client_metadata_and_response_bounds", clientMetadataAndResponseBounds};

}
