#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <lauxlib.h>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>

#include <climits>
#include <exception>
#include <iostream>

import telar.testing;
import telar.gui.features.components;
import telar.gui.foundation.actions;
import telar.gui.features.machines;

import telar.gui.application;
import telar.gui.features.status_bar;
import telar.gui.foundation.core;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::machines;

  struct Fixture {
    static constexpr std::uint64_t generation = 42;
    static constexpr std::uint16_t year = 2026;
    static constexpr std::uint8_t weekday = 6;
    static constexpr std::uint8_t cpu = 73;
    static constexpr std::uint16_t used_memory = 123;
    static constexpr std::uint16_t cpu_count = 8;
    static constexpr std::uint16_t total_memory = 320;
    static constexpr std::uint16_t panel_width = 460;
    static constexpr std::chrono::milliseconds interval{250};
  };

  void builtinContent() {
    const auto metrics = features::components::builtinContent(features::components::SourceKind::metrics);
    const auto nodes = metrics.nodes();

    check(nodes.size() == 4 && nodes.front().kind == features::components::Kind::group && nodes.front().parent == features::components::Node::no_parent, "builtin metrics must retain the original root group");
    check(metrics.text(nodes.front().text) == "system", "builtin metrics must name their summary");
    constexpr telar::ds::Array names{BarMetric::battery, BarMetric::cpu, BarMetric::memory};

    for (std::size_t index = 0; index < names.size(); ++index) {
      const auto& node = nodes[index + 1];

      check(node.kind == features::components::Kind::metric && node.parent == 0 && node.metric == names[index], "builtin metrics must list their arcs from the battery, then CPU and memory");
    }

    for (const auto& node : nodes) {
      check(node.priority == features::components::builtin_priority && !metrics.action(node), "builtin metrics must yield at original priority without configured callbacks");
    }

    const auto machines = features::components::builtinContent(features::components::SourceKind::machines);

    check(machines.nodes().size() == 1 && machines.nodes().front().kind == features::components::Kind::machines && machines.nodes().front().parent == features::components::Node::no_parent && machines.nodes().front().priority == features::components::builtin_priority, "builtin machines must be one original-priority root");
    check(!machines.action(machines.nodes().front()), "builtin machine controls must retain their dedicated routing");
    for (const auto kind : {features::components::SourceKind::empty, features::components::SourceKind::tabs, features::components::SourceKind::fixed, features::components::SourceKind::dynamic, features::components::SourceKind::command}) {
      check(!features::components::builtinSource(kind) && features::components::builtinContent(kind).empty(), "other source kinds must not acquire builtin nodes");
    }
  }

  template <typename Value>
  Value required(telar::ds::Option<Value> value) {
    if (!value) {
      throw std::runtime_error{"Expected a retained component action"};
    }

    return *value;
  }

  constexpr std::string_view source = R"(
local t = require('telar')
local ui = t.ui
return {api_version = 2, client = {
  keybindings = {t.bind({'alt+u'}, t.action.open_panel('zebra'))},
  panels = {
    zebra = t.panel({title = 'Usage', width = 460, render = function(ctx)
      return {ui.heading(ctx.pane_title), ui.actions({ui.button({text='Close', action=t.action.close_panel()})})}
    end}),
    alpha = t.panel({render = function(ctx) return ui.text('First by name') end}),
  },
  picks = {mode = t.pick({items = {'low', 'high'}, on_select = {'helper', '{}'}})},
  bars = {bottom = {
    left = t.bar.static(ui.group({on_click=t.action.open_panel('zebra'), url='https://action-fallback.test', ui.label('á λ')})),
    center = t.bar.tabs(),
    right = t.bar.dynamic({every_ms=250, render = function(ctx)
      assert(ctx.time.year == 2026 and ctx.time.weekday == 6)
      assert(ctx.metrics.available and ctx.metrics.cpu_percent == 73)
      assert(ctx.metrics.memory_used_decigib == 123 and ctx.metrics.battery_percent == nil)
      assert(ctx.sidebar_visible and ctx.active_tab_index == 2)
      if ctx.output == 'immutable' then ctx.time.hour = 0 end
      if ctx.output == 'infinite' then while true do end end
      local content = {ui.group({on_click=t.action.open_panel('zebra'), ui.label(ctx.pane_title)})}
      if ctx.output == 'invalid' then content[#content+1] = ui.label('bad\n') end
      return content
    end}),
  }, top = {right=t.bar.command({command={'helper', 'a b', '$(literal)'}, every_ms=1000})}},
}, profiles = {
  inherited = {client = {pane_gaps=false}},
  reindexed = {client = {panels = {zebra = t.panel({render = function(ctx) return ui.text('Profile panel') end})}}},
  replaced = {client = {bars = {bottom = {left=t.bar.tabs(), right=t.bar.static('override')}}}},
}}
)";

  application::ConfigurationSourceText selection(std::string_view profile = {}) {
    return {.source = source, .directory = {}, .profile = profile, .generation = Fixture::generation};
  }

  features::components::Context context() {
    features::components::Context result;

    result.client.active_tab_index = 1;
    result.time.year = Fixture::year;
    result.time.weekday = Fixture::weekday;
    result.metrics = telar::SystemMetrics{.revision = 1, .cpu_percent = Fixture::cpu, .memory_used_decigib = Fixture::used_memory, .has_battery = false, .battery_percent = 0, .cpu_count = Fixture::cpu_count, .memory_total_decigib = Fixture::total_memory};
    result.pane_title = "Working λ";

    return result;
  }

  template <typename Memory>
  void profilesAndDefinitions(Memory& memory) {
    const application::ConfigurationGeneration base{memory, selection("inherited")};
    const auto& configuration = base.components();
    const auto& definitions = configuration.definitions();

    check(definitions.panels().size() == 2 && definitions.panels()[0].heading.name.view() == "alpha" && definitions.panels()[1].heading.name.view() == "zebra", "panel names must be retained in action-index order");
    check(definitions.panels()[1].width == Fixture::panel_width && !definitions.panels()[1].source.interval, "panels without every_ms must render only on open/refresh");
    check(definitions.picks().size() == 1 && definitions.picks()[0].refresh, "static picks must retain their default refresh policy");
    check(definitions.source(features::components::Position::bottom_center).kind == features::components::SourceKind::tabs && definitions.source(features::components::Position::bottom_right).interval == Fixture::interval, "an unrelated profile must inherit source positions and cadence");
    const auto& bar = configuration.bar(features::components::Position::bottom_left);

    check(bar.nodes().size() == 2 && bar.text(bar.nodes()[1].text) == "á λ", "static source text must be copied into owned content");
    const auto action = bar.action(bar.nodes()[0]);
    const auto definition = action ? base.definitionAction(*action) : telar::ds::none;

    check(definition && definition->kind == DefinitionActionDescription::Kind::panel && definition->index == 1, "static component actions must resolve sorted panel indices");
    check(bar.text(bar.nodes().front().url) == "https://action-fallback.test", "components with an action must also retain their configured URL");
    std::size_t argument = 0;
    constexpr auto expected = telar::ds::Array<std::string_view, 3>{"helper", "a b", "$(literal)"};

    base.visitArguments(definitions.source(features::components::Position::top_right).reference, "command", [&](std::string_view value) {
      check(argument < expected.size() && value == expected[argument], "command argv must retain literal argument boundaries");
      ++argument;
    });

    check(argument == expected.size(), "all command arguments must be retained");

    const application::ConfigurationGeneration replaced{memory, selection("replaced")};
    const auto& overlay = replaced.components();

    check(overlay.definitions().source(features::components::Position::bottom_left).kind == features::components::SourceKind::tabs && overlay.definitions().source(features::components::Position::bottom_center).kind == features::components::SourceKind::empty, "a declared bottom bar must replace omitted slots");
    check(overlay.bar(features::components::Position::bottom_left).empty() && overlay.bar(features::components::Position::bottom_right).text(overlay.bar(features::components::Position::bottom_right).nodes()[0].text) == "override", "inherited static content must not leak into replaced slots");
    const application::ConfigurationGeneration reindexed{memory, selection("reindexed")};
    const auto inherited_binding = reindexed.definitionAction(reindexed.input().configured[0].action);

    check(inherited_binding && inherited_binding->index == 0 && reindexed.components().definitions().panels().size() == 1, "inherited bindings must resolve panel names against the selected profile rather than reuse base indices");
  }

  template <typename Memory, typename Budget>
  void footerValidation(Memory& memory, const Budget& budget) {
    struct InvalidFooter {
      std::string_view source;
      std::string_view diagnostic;
      std::string_view profile;
    };

    constexpr telar::ds::Array invalid{
        InvalidFooter{R"(local t=require('telar'); return {api_version=2,client={bars={sidebar_footer={t.bar.metrics(),t.bar.machines(),t.bar.static('third'),t.bar.static('fourth')}}}})", "config.client.bars.sidebar_footer accepts at most 3 slots", {}},
        InvalidFooter{R"(local t=require('telar'); return {api_version=2,client={bars={sidebar_footer={t.bar.tabs()}}}})", "config.client.bars.sidebar_footer cannot contain tabs", {}},
        InvalidFooter{R"(local t=require('telar'); return {api_version=2,client={bars={sidebar_footer={t.bar.static('first'),t.bar.metrics(),t.bar.tabs()}}}})", "config.client.bars.sidebar_footer cannot contain tabs", {}},
        InvalidFooter{R"(local t=require('telar'); return {api_version=2,profiles={bad={client={bars={sidebar_footer={t.bar.tabs()}}}}}})", "config.client.bars.sidebar_footer cannot contain tabs", "bad"},
    };

    for (const auto& example : invalid) {
      bool rejected = false;

      try {
        const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = example.source, .directory = {}, .profile = example.profile}};
      } catch (const std::exception& error) {
        if (error.what() != example.diagnostic) {
          std::cerr << "Unexpected footer diagnostic: " << error.what() << '\n';
        }

        check(error.what() == example.diagnostic, "invalid footer must retain its original contextual diagnostic");
        rejected = true;
      }

      check(rejected, "sidebar footer must reject excess slots and tabs in base or selected profile");
      check(budget.liveBytes() == 0, "failed footer configuration must release every injected allocation");
    }

    constexpr std::string_view valid = R"(
    local t=require('telar')
    return {api_version=2,client={bars={sidebar_footer={t.bar.metrics(),t.bar.machines(),t.bar.static('third')}}},profiles={
      inherited={client={pane_gaps=false}},
      empty={client={bars={sidebar_footer={}}}},
      shorter={client={bars={sidebar_footer={t.bar.static('only')}}}},
    }}
  )";
    constexpr telar::ds::Array positions{features::components::Position::footer_left, features::components::Position::footer_center, features::components::Position::footer_right};

    {
      const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = valid, .directory = {}, .profile = "inherited"}};
      constexpr telar::ds::Array kinds{features::components::SourceKind::metrics, features::components::SourceKind::machines, features::components::SourceKind::fixed};

      for (std::size_t index = 0; index < positions.size(); ++index) {
        check(generation.components().definitions().source(positions[index]).kind == kinds[index], "valid footer must retain all three ordered sources through inheritance");
      }

      const auto& bar = generation.components().bar(features::components::Position::footer_right);

      check(bar.nodes().size() == 1 && bar.text(bar.nodes().front().text) == "third", "valid footer must retain owned static content");
    }

    for (const auto* const profile : {"empty", "shorter"}) {
      const application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = valid, .directory = {}, .profile = profile}};
      const bool empty = std::string_view{profile} == "empty";

      for (std::size_t index = 0; index < positions.size(); ++index) {
        const auto expected = !empty && index == 0 ? features::components::SourceKind::fixed : features::components::SourceKind::empty;

        check(generation.components().definitions().source(positions[index]).kind == expected, "declared footer list must replace inherited omitted slots");
      }
    }
  }

  template <typename Generation>
  bool rejectedAction(const Generation& generation, BindingAction action) {
    try {
      static_cast<void>(generation.definitionAction(action));
    } catch (const std::invalid_argument&) {
      return true;
    }

    return false;
  }

  template <typename Memory>
  void renderLifetime(Memory& memory) {
    application::ConfigurationGeneration generation{memory, selection()};
    auto snapshot = context();
    constexpr auto position = features::components::Position::bottom_right;

    generation.renderBar(position, snapshot);
    const auto& bar = generation.components().bar(position);

    check(bar.nodes().size() == 2 && bar.text(bar.nodes()[1].text) == snapshot.pane_title, "dynamic sources must receive the immutable render context");
    auto action = required(bar.action(bar.nodes()[0]));
    constexpr std::size_t renders = 2000;

    for (std::size_t index = 0; index < renders; ++index) {
      generation.renderBar(position, snapshot);
      const auto next = required(bar.action(bar.nodes()[0]));

      check(next != action && rejectedAction(generation, action) && required(generation.definitionAction(next)).index == 1, "old action identities must be rejected even when Lua registry references are reused");
      action = next;
    }

    for (const auto* const failure : {"invalid", "immutable", "infinite"}) {
      snapshot.output = failure;
      bool rejected = false;

      try {
        generation.renderBar(position, snapshot);
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected && required(bar.action(bar.nodes()[0])) == action && bar.text(bar.nodes()[1].text) == "Working λ", "failed or over-budget renders must retain the last complete content and its action references");
      check(required(generation.definitionAction(action)).index == 1, "a failed render must leave the prior action usable");
    }

    snapshot.output.reset();
    generation.renderPanel(1, snapshot);
    const auto& panel = generation.components().panel();

    check(panel.nodes().size() == 3 && panel.nodes()[2].kind == features::components::Kind::button && required(panel.action(panel.nodes()[2])).kind == BindingActionKind::close_panel, "open panels must parse block content and native button actions");
    generation.closePanel();
    check(panel.empty(), "closing a panel must release its content");
    auto obsolete = action;

    ++obsolete.generation;
    check(rejectedAction(generation, obsolete), "component actions must reject a different configuration generation");
  }

  template <typename Memory>
  void pickRendering(Memory& memory) {
    constexpr std::string_view configuration = R"(
    local t = require('telar')
    return {api_version=2, client={picks={
      a=t.pick({items={'low',{label='Unicode λ',value='a\tb',selected=true}},on_select={'helper','{}'}}),
      b=t.pick({command={'helper'},on_select={'helper','{}'}}),
      c=t.pick({command={'helper'},items=function(ctx)
        if ctx.output == 'infinite' then while true do end end
        if ctx.output == 'immutable' then ctx.time.hour=0 end
        if ctx.output == 'invalid' then return {'bad\n'} end
        return {{label=ctx.output,detail=ctx.pane_title}}
      end,on_select={'helper','{}'}}),
    }}}
  )";
    application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = configuration, .directory = {}, .profile = {}}};
    features::components::PickItems items;
    auto invocation = context();

    generation.renderPick(0, invocation, items);
    check(items.size() == 2 && items.at(1).value == "a\tb" && items.at(1).selected, "static pick metadata and literal values must survive parsing");
    invocation.output = " low \n a\tb \n";
    generation.renderPick(1, invocation, items);
    check(items.size() == 2 && items.at(1).label == "a b" && items.at(1).value == "a\tb", "command picks must parse complete raw lines with literal values");
    invocation.output = "Result λ";
    generation.renderPick(2, invocation, items);
    check(items.size() == 1 && items.at(0).label == "Result λ" && items.at(0).detail == "Working λ", "pick callbacks must receive command output and readonly client context");

    features::components::PickItems failed;

    for (const auto* const failure : {"infinite", "immutable", "invalid"}) {
      invocation.output = failure;
      bool rejected = false;

      try {
        generation.renderPick(2, invocation, failed);
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "failed pick callbacks must report their failure");
    }

    generation.renderPick(0, invocation, items);
    check(items.size() == 2, "a failed pick callback must leave the VM usable");
  }

  template <typename Memory>
  void elementRendering(Memory& memory) {
    constexpr auto configuration = R"(
    local t=require('telar');local ui=t.ui
    local clicks=0
    return {api_version=2, client={
      panels={details=t.panel({render=function() return ui.text('Details') end})},
      components={
        tab=function(ctx, tab)
          if tab.title == 'loop' then while true do end end
          if tab.title == 'unknown' then return ui.row({wobble=1}) end
          if tab.title == 'builtin' then return ui.builtin('nothing') end
          local cards={height=22}
          for index, pane in ipairs(tab.panes) do cards[#cards+1]=ui.tile({id=pane.program, program=pane.program, x=(index-1)*7, rotation=-8, z=-2, transition={duration=180, easing='linear'}}) end
          return ui.row({
            width=180, padding={2, 10}, gap=6, align='center', background='#ff000080',
            ui.stack(cards),
            'plain ' .. clicks,
            ui.label({text=tab.title, bold=true, grow=1, on_click=t.action.open_panel('details')}),
            ui.icon({name='close', on_click=function() clicks=clicks+1; return t.action.toggle_sidebar() end}),
            ui.canvas({width=16, height=16, ops={{'circle', 8, 8, 6}, {'stroke', 'accent', 2}, {'path', 'M0 0 L4 4 Z'}, {'fill', '#ffffff'}}}),
            ui.builtin('tab_cards'),
          })
        end,
      },
    }}
  )";
    application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = configuration, .directory = {}, .profile = {}}};

    check(generation.components().definitions().slot(features::components::Slot::tab) != LUA_NOREF && generation.components().definitions().slot(features::components::Slot::pane_header) == LUA_NOREF, "component slots must keep only the functions a configuration names");
    const auto invocation = context();
    constexpr std::uint64_t instance = 7;
    const auto rendered = generation.renderElements(features::components::Slot::tab, instance, invocation, R"({"title":"Tab λ","panes":[{"program":"nvim"},{"program":"git"}]})");
    const auto& elements = rendered->elements;
    using Kind = features::components::ElementKind;
    // The row, its stack with a tile per pane, then the row's other children in document order.
    constexpr std::size_t element_count = 9;
    constexpr std::size_t title_element = 5;
    constexpr std::size_t click_element = 6;
    constexpr std::size_t canvas_element = 7;
    constexpr std::size_t builtin_element = 8;
    // What the configuration gives the row and its tiles.
    constexpr float row_width = 180;
    constexpr float horizontal_padding = 10;
    constexpr std::uint8_t background_alpha = 0x80;
    constexpr std::uint16_t transition_ms = 180;

    check(elements.size() == element_count, "an element tree must keep every element in document order");
    check(elements[0].kind == Kind::row && elements[0].width == row_width && elements[0].padding == telar::ds::Array<float, 4>{horizontal_padding, 2, horizontal_padding, 2} && elements[0].background.alpha == background_alpha, "boxes must read sizes, CSS-ordered padding and colors with alpha");
    check(elements[1].kind == Kind::stack && elements[2].kind == Kind::tile && elements[2].parent == 1 && rendered->view(elements[2].key) == "nvim" && elements[2].z == -2 && elements[2].transition_ms == transition_ms && elements[2].easing == 1, "stacks must hold keyed tiles with their poses and transitions");
    check(elements[4].kind == Kind::label && rendered->view(elements[4].text) == "plain 0", "a string inside a container must become a label");
    check(rendered->view(elements[title_element].text) == "Tab λ" && elements[title_element].bold && elements[title_element].grow == 1, "labels must keep the item text and their style");
    check(elements[title_element].action != features::components::Element::none, "action tables must become element actions");
    const auto* action = rendered->actions.find(rendered->bindings[elements[title_element].action]);

    check(action != nullptr && action->description && std::holds_alternative<DefinitionActionDescription>(*action->description), "element actions must be resolved when the render finishes");
    check(elements[click_element].named && elements[click_element].callback == 0 && rendered->callbacks == 1, "on_click functions must be kept as handlers of their instance");
    check(elements[canvas_element].kind == Kind::canvas && elements[canvas_element].steps_count == 4 && rendered->steps[elements[canvas_element].steps_offset + 1].count == 1, "canvas operations must keep their values and optional widths");
    check(elements[builtin_element].kind == Kind::builtin && rendered->view(elements[builtin_element].text) == "tab_cards", "built-in pieces must name a known piece");

    const auto effects = generation.invokeElement(instance, 0, invocation, R"({"title":"Tab λ","panes":[]})");

    check(effects->effects.length == 1 && effects->effects.actions[0].kind == BindingActionKind::toggle_sidebar, "a click function must return its actions");
    const auto again = generation.renderElements(features::components::Slot::tab, instance, invocation, R"({"title":"Tab λ","panes":[]})");

    check(again->view(again->elements[2].text) == "plain 1", "a click function's state must reach the next render");

    for (const auto* const title : {"loop", "unknown", "builtin"}) {
      bool rejected = false;

      try {
        static_cast<void>(generation.renderElements(features::components::Slot::tab, instance, invocation, std::string{R"({"title":")"} + title + R"(","panes":[]})"));
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "runaway, unknown and invalid elements must fail the render");
    }

    const auto effects_after = generation.invokeElement(instance, 0, invocation, "{}");

    check(effects_after->effects.length == 1, "a failed render must keep the handlers of the last valid one");
    generation.forgetElements(instance);
    bool forgotten = false;

    try {
      static_cast<void>(generation.invokeElement(instance, 0, invocation, "{}"));
    } catch (const std::invalid_argument&) {
      forgotten = true;
    }

    check(forgotten, "a forgotten instance must release its handlers");
  }

  // Every documented mod must load and render each slot it names.
  template <typename Memory>
  void exampleMods(Memory& memory) {
    telar::ds::Array<char, PATH_MAX> directory{};

    check(::realpath(TELAR_GUI_EXAMPLES_DIR, directory.dataMut()) != nullptr, "the documented examples must exist");

    struct Sample {
      features::components::Slot slot{};
      std::string_view item;
    };

    constexpr telar::ds::Array samples{
        Sample{features::components::Slot::tab, R"({"index":1,"key":"4","title":"nvim","label":"nvim","path":"~/src","application":"nvim","selected":true,"attention":true,"panes":[{"key":"1","program":"nvim","focused":false,"attention":true},{"key":"2","program":"git","focused":true,"attention":false}]})"},
        Sample{features::components::Slot::pane_header, R"({"id":"2","index":1,"program":"claude","context":"~/src","focused":true,"fullscreen":false,"images_paused":false,"needs_attention":false,"progress":""})"},
        Sample{features::components::Slot::agent_card, R"({"key":"a","title":"Fix","project":"telar","detail":"","provider":"Claude","status":"working","selected":false,"depth":0,"plan":{"done":1,"total":3,"step":"Test"}})"},
        Sample{features::components::Slot::top_bar, R"({"workspace":"telar","machine":"laptop","tab_count":2,"sidebar_visible":true})"},
        Sample{features::components::Slot::bottom_bar, R"({"workspace":"telar","machine":"laptop","tab_count":2,"sidebar_visible":true})"},
    };

    constexpr telar::ds::Array mods{"stack-tabs", "default-tab", "default-pane-header", "default-card", "default-top-bar", "default-bottom-bar"};
    std::size_t rendered = 0;

    for (const auto* const name : mods) {
      const auto source = std::string{"return {api_version=2,client={components=require('mods."} + name + "')}}";
      application::ConfigurationGeneration generation{memory, application::ConfigurationSourceText{.source = source, .directory = directory.data(), .profile = {}}};

      for (const auto& sample : samples) {
        if (generation.components().definitions().slot(sample.slot) == LUA_NOREF) {
          continue;
        }

        const auto elements = generation.renderElements(sample.slot, 1, context(), sample.item);

        check(!elements->elements.empty(), "an example mod must draw something for each slot it names");
        ++rendered;
      }
    }

    check(rendered == mods.size(), "every example mod must name a slot");
  }

  // Runs `run` with an injected budget, which it must give back whole.
  template <typename Run>
  void budgeted(Run run) {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    run(memory, budget);
    check(budget.liveBytes() == 0, "component configuration teardown must release every injected allocation");
  }

  void budgetedProfilesAndDefinitions() {
    budgeted([](telar::Memory& memory, const auto&) {
      profilesAndDefinitions(memory);
    });
  }

  void budgetedFooterValidation() {
    budgeted([](telar::Memory& memory, const auto& budget) {
      footerValidation(memory, budget);
    });
  }

  void budgetedRenderLifetime() {
    budgeted([](telar::Memory& memory, const auto&) {
      renderLifetime(memory);
    });
  }

  void budgetedPickRendering() {
    budgeted([](telar::Memory& memory, const auto&) {
      pickRendering(memory);
    });
  }

  void budgetedElementRendering() {
    budgeted([](telar::Memory& memory, const auto&) {
      elementRendering(memory);
    });
  }

  void budgetedExampleMods() {
    budgeted([](telar::Memory& memory, const auto&) {
      exampleMods(memory);
    });
  }

  const telar::testing::Case case_builtin_content{"component_configuration.builtin_content", builtinContent};
  const telar::testing::Case case_profiles_and_definitions{"component_configuration.profiles_and_definitions", budgetedProfilesAndDefinitions};
  const telar::testing::Case case_footer_validation{"component_configuration.footer_validation", budgetedFooterValidation};
  const telar::testing::Case case_render_lifetime{"component_configuration.render_lifetime", budgetedRenderLifetime};
  const telar::testing::Case case_pick_rendering{"component_configuration.pick_rendering", budgetedPickRendering};
  const telar::testing::Case case_element_rendering{"component_configuration.element_rendering", budgetedElementRendering};
  const telar::testing::Case case_example_mods{"component_configuration.example_mods", budgetedExampleMods};

}
