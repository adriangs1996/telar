#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <stdexcept>
#include <string_view>

#include <climits>
#include <exception>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.foundation.core;
import telar.gui.foundation.actions;
import telar.lua;

import telar.config.snapshot;
import telar.gui.application;
import telar.config.runtime;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  constexpr std::string_view config_bootstrap{
#include "gui_config_bootstrap.inc"
  };

  struct ConfigurationExample {
    std::string_view source;
    std::string_view profile;
  };

  Configuration read(ConfigurationExample example) {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    Configuration result;

    {
      telar::runtime::lua::Vm<telar::Memory> machine{memory};

      machine.execute(config_bootstrap, "@bootstrap.lua", 0);
      machine.execute(example.source, "@test.lua");
      // As a configuration generation reads it: validated by the library's reader first.
      const telar::runtime::lua::Value root{machine.state(), -1, "config"};
      auto values = telar::ds::makeBox<telar::runtime::config::RuntimeValues<telar::Memory>>(memory, memory);

      telar::runtime::config::SnapshotReader{memory, values.getMut()}.read(root, example.profile);
      result = application::ConfigurationReader::read(root, example.profile);
    }

    if (budget.liveBytes() != 0) {
      throw std::runtime_error{"Configuration VM leaked injected allocations"};
    }

    return result;
  }

  void promptPreferences() {
    const auto configuration = read({.source = R"(return {api_version = 2, client = {prompt = {mode = "telar", keymap = "vim", motion = "none", ghost = false, max_lines = 4}}})", .profile = {}});
    const auto& prompt = configuration.prompt;

    check(prompt.mode == PromptMode::telar && prompt.keymap == PromptKeymap::vim && prompt.motion == PromptMotion::none && !prompt.ghost && prompt.max_lines == 4, "every prompt field must be read");
    check(read({.source = R"(return {api_version = 2, client = {prompt = {mode = "telar", skin = "glass"}}})", .profile = {}}).prompt.mode == PromptMode::telar, "client.prompt.skin is accepted as the documentation describes it");
    check(read({.source = "return {api_version = 2}", .profile = {}}).prompt == PromptConfiguration(), "the prompt stays classic by default");
    const auto bound = read({.source = R"(return {api_version = 2, client = {prompt = {bindings = {{keys = "ctrl+j", action = "submit"}, {keys = "H", action = "line_start", mode = "normal"}}}}})", .profile = {}});

    check(bound.prompt.bindings.size() == 2 && bound.prompt.bindings[0].character == 'j' && bound.prompt.bindings[1].normal && bound.prompt.bindings[1].action == static_cast<std::uint8_t>(application::prompt::Action::line_start), "prompt bindings must be read with their action and mode");
    constexpr auto invalid_sources = telar::ds::Array<std::string_view, 6>{R"(return {api_version = 2, client = {prompt = {mode = "fancy"}}})", R"(return {api_version = 2, client = {prompt = {max_lines = 0}}})", R"(return {api_version = 2, client = {prompt = {keymap = "helix"}}})", R"(return {api_version = 2, client = {prompt = {skin = "neon"}}})", R"(return {api_version = 2, client = {prompt = {ambient = true}}})", R"(return {api_version = 2, client = {prompt = {bindings = {{keys = "ctrl+j", action = "explode"}}}}})"};

    for (const auto source : invalid_sources) {
      bool rejected = false;

      try {
        read({.source = source, .profile = {}});
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "invalid prompt configuration must not be silently accepted");
    }
  }

  // The bindings are a value of fixed size: equal by the keys they bind, full at the most the
  // configuration reads.
  void promptBindingsValue() {
    const PromptBinding first{.key = 1, .character = 'j', .action = 2};
    const PromptBinding second{.key = 1, .character = 'H', .action = 8, .normal = true};
    PromptBindings built;

    built.push(first);
    built.push(second);
    check(built == PromptBindings{first, second} && built.size() == 2 && built[1].normal, "bindings pushed one by one equal the same listed");
    check(!(built == PromptBindings{first}) && PromptBindings{} == PromptBindings{}, "a binding more or less tells them apart");

    PromptBindings full;

    for (std::size_t index = 0; index < PromptBindings::capacity; ++index) {
      full.push(first);
    }

    bool refused = false;

    try {
      full.push(second);
    } catch (const std::length_error&) {
      refused = true;
    }

    check(refused && full.size() == PromptBindings::capacity, "a binding past the capacity is refused");
  }

  void historyPreferences() {
    const auto configuration = read({.source = R"(return {api_version = 2, client = {history = {show_agent_commands = true, enter = "run", match = "fts"}}, profiles = {paste = {client = {history = {enter = "paste"}}}}})", .profile = "paste"});

    check(configuration.history.show_agent_commands && !configuration.history.enter_runs && configuration.history.match_fts, "history profile fields must override independently and retain inherited choices");
    const auto defaults = read({.source = "return {api_version = 2}", .profile = {}});

    check(!defaults.history.show_agent_commands && !defaults.history.enter_runs && !defaults.history.match_fts, "history defaults must keep the human-only fuzzy paste behavior");

    constexpr auto invalid_sources = telar::ds::Array<std::string_view, 3>{R"(return {api_version = 2, client = {history = {enter = "exec"}}})", R"(return {api_version = 2, client = {history = {match = "regex"}}})", R"(return {api_version = 2, client = {history = {show_agent_commands = "yes"}}})"};

    for (const auto source : invalid_sources) {
      bool rejected = false;

      try {
        read({.source = source, .profile = {}});
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "invalid history configuration must not be silently accepted");
    }
  }

  void independentBackgroundOpacity() {
    using Surface = BackgroundOpacity::Surface;
    // The opacities the configuration below gives the sidebar and the panes.
    constexpr float sidebar_opacity = 0.5F;
    constexpr float pane_opacity = 0.25F;
    const auto inherited = read({.source = R"(return {api_version=2,gui={window={background_opacity=0.75},opacity={sidebar=0.5,pane=0.25}},profiles={other={gui={window={background_opacity=1},opacity={topbar=0}}}}})", .profile = "other"});

    check(inherited.opacity.resolve(Surface::sidebar, inherited.background_opacity) == sidebar_opacity && inherited.opacity.resolve(Surface::pane, inherited.background_opacity) == pane_opacity, "profiles must preserve explicit surface opacities");
    check(inherited.opacity.resolve(Surface::topbar, inherited.background_opacity) == 0 && inherited.opacity.resolve(Surface::workspace, inherited.background_opacity) == 1, "unconfigured regions must inherit the adopted global value, including profile changes");
    check(inherited.opacity.minimum(inherited.background_opacity) == 0, "the native window must allow transparency when any region needs it");
    BackgroundOpacity opaque;
    constexpr float translucent_window = 0.25F;

    opaque.overrides.fill(1.0F);
    check(opaque.minimum(translucent_window) == 1, "fully opaque overrides must not retain unnecessary native transparency or blur");
    for (const auto* source : {R"(return {api_version=2,gui={opacity={pane=-0.01}}})", R"(return {api_version=2,gui={opacity={sidebar=1.01}}})", R"(return {api_version=2,gui={opacity={topbar=false}}})", R"(return {api_version=2,gui={opacity={workspace=0/0}}})", R"(return {api_version=2,gui={opacity={pane=math.huge}}})", R"(return {api_version=2,gui={opacity={unknown=0.5}}})"}) {
      bool rejected = false;

      try {
        read({.source = source, .profile = {}});
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "invalid surface opacity must fail before adoption");
    }
  }

  void editorPreferences() {
    const auto inherited = read({.source = R"(return {api_version=2, client={editor="nvim"}, profiles={other={client={editor="/opt/Editor With Spaces"}}, inherited={client={pane_gaps=false}}}})", .profile = "inherited"});

    check(inherited.editor.view() == "nvim", "unrelated profile fields must preserve the configured editor");
    const auto overridden = read({.source = R"(return {api_version=2, client={editor="nvim"}, profiles={other={client={editor="/opt/Editor With Spaces"}}}})", .profile = "other"});

    check(overridden.editor.view() == "/opt/Editor With Spaces", "profile editors must override the inherited executable as one value");
    for (const auto* const source : {R"(return {api_version=2,client={editor=""}})", R"(return {api_version=2,client={editor="a\nb"}})", R"(return {api_version=2,client={editor=42}})"}) {
      bool rejected = false;

      try {
        read({.source = source, .profile = {}});
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "invalid editor values must fail before configuration adoption");
    }
  }

  void windowTitlePreferences() {
    const auto inherited = read({.source = R"(return {api_version=2, client={window_title="{workspace}: {tab}"}, profiles={inherited={client={pane_gaps=false}}, replaced={client={window_title="{hostname}"}}, cleared={client={window_title=""}}}})", .profile = "inherited"});

    check(inherited.window_title.view() == "{workspace}: {tab}", "unrelated profile values must preserve the inherited title template after Lua teardown");
    const auto cleared = read({.source = R"(return {api_version=2,client={window_title="{tab}"},profiles={cleared={client={window_title=""}}}})", .profile = "cleared"});

    check(cleared.window_title.view().empty(), "an empty profile template must clear the inherited title");
    const auto replaced = read({.source = R"(return {api_version=2,client={window_title="{tab}"},profiles={replaced={client={window_title="{hostname}"}}}})", .profile = "replaced"});

    check(replaced.window_title.view() == "{hostname}", "a profile title must replace the inherited template");
    for (const auto* const source : {R"(return {api_version=2,client={window_title=42}})", R"(return {api_version=2,client={window_title="a\nb"}})", R"(return {api_version=2,client={window_title=string.rep("a",129)}})"}) {
      bool rejected = false;

      try {
        read({.source = source, .profile = {}});
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "invalid title templates must fail before adoption");
    }
  }

  void sidebarWidthPreferences() {
    const auto defaults = read({.source = R"(return {api_version=2})", .profile = {}});

    check(defaults.sidebar_width_auto, "the sidebar fits its content unless a width is configured");
    const auto fixed = read({.source = R"(return {api_version=2,gui={sidebar={width=320}},profiles={automatic={gui={sidebar={width="auto"}}}}})", .profile = {}});
    constexpr float fixed_width = 320;

    check(!fixed.sidebar_width_auto && fixed.sidebar_width == fixed_width, "a numeric width fixes the sidebar");
    const auto automatic = read({.source = R"(return {api_version=2,gui={sidebar={width=320}},profiles={automatic={gui={sidebar={width="auto"}}}}})", .profile = "automatic"});

    check(automatic.sidebar_width_auto, "a profile can return the sidebar to its automatic width");
    bool rejected = false;

    try {
      read({.source = R"(return {api_version=2,gui={sidebar={width="wide"}}})", .profile = {}});
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected, "a sidebar width is a number or \"auto\"");
  }

  void keymapProfilesAndCallbacks() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
          .source = R"(
      local calls = 0
      return {api_version = 2, client = {
        prefix = 'ctrl+a',
        keybindings = {
          telar.bind({'g', 'g'}, function(context)
            calls = calls + 1
            assert(context.active_tab_index == 2 and context.focused_pane_id == 3)
            return {telar.action.toggle_sidebar(), telar.action.select_tab{index = calls}}
          end),
          telar.bind_global({'alt+x'}, 'new-tab')
        }
      }, profiles = {other = {client = {prefix = 'ctrl+o', input = {sequence_timeout_ms = 250}}}}}
    )",
          .directory = {},
          .profile = "other",
      };

      application::ConfigurationGeneration generation{memory, source};
      const auto& input = generation.input();
      constexpr auto control = static_cast<unsigned>(KeyChord::Modifier::control);

      check(input.length == 2 && input.prefix == KeyChord{.key = KeyChord::Key::character, .character = 'o', .modifiers = control}, "profile prefixes must replace the default and inherited binding prefixes");
      check(input.configured[0].length == 3 && input.configured[0].keys[0] == input.prefix && input.configured[1].length == 1, "prefixed and global sequences must compile with their full declared length");
      constexpr std::uint64_t expected_timeout_ns = std::uint64_t{250} * 1000 * 1000;

      check(input.sequence_timeout_ns == expected_timeout_ns, "input sequence timeouts must use the selected profile");
      const BindingContext context{.active_tab_index = 1, .focused_pane_id = 3};
      const auto first = generation.invoke(input.configured[0].action, context);
      const auto second = generation.invoke(input.configured[0].action, context);

      check(first.length == 2 && first.actions[0].kind == BindingActionKind::toggle_sidebar && first.actions[1].parameter == 0 && second.actions[1].parameter == 1, "callback closures must survive configuration loading and retain validated action order");
    }

    check(budget.liveBytes() == 0, "retained configuration generations must release their VM through the injected allocator");
  }

  void inputExpressions() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
    return {api_version = 2, client = {keybindings = {
      telar.bind_expr({'a'}, function() return telar.input.forward() end),
      telar.bind_expr_global({'alt+b'}, function() return telar.input.keys({'ctrl+c', 'enter', '🌱'}) end),
      telar.bind_expr({'c'}, function() return telar.input.paste('one\ntwo') end),
      telar.bind_expr({'d'}, function() return telar.input.consume() end)
    }}}
  )",
        .directory = {},
        .profile = "",
    };

    application::ConfigurationGeneration generation{memory, source};
    const auto& bindings = generation.input().configured;
    const auto forward = generation.expression(bindings[0].action, {});

    check(forward.kind == InputExpression::Kind::forward && forward.length == bindings[0].length && forward.keys[0] == generation.input().prefix, "forward expressions must replay the entire effective trigger including its prefix");
    const auto keys = generation.expression(bindings[1].action, {});

    check(keys.kind == InputExpression::Kind::keys && keys.length == 3 && keys.keys[1].key == KeyChord::Key::enter, "key expressions must parse complete named and Unicode chords");
    const auto paste = generation.expression(bindings[2].action, {});

    check(paste.kind == InputExpression::Kind::paste && paste.paste.view() == "one\ntwo", "paste expressions must own the complete Lua result");
    check(generation.expression(bindings[3].action, {}).kind == InputExpression::Kind::consume, "consume expressions must generate no input");
  }

  void invalidCallbacksAndRecovery() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
    return {api_version = 2, client = {keybindings = {
      telar.bind({'a'}, function(context) context.sidebar_visible = false return {} end),
      telar.bind({'b'}, function() return {telar.action.new_tab(), function() end} end),
      telar.bind({'c'}, function() while true do end end),
      telar.bind({'d'}, function() return telar.action.new_tab() end)
    }}}
  )",
        .directory = {},
        .profile = "",
    };

    application::ConfigurationGeneration generation{memory, source};
    const auto& bindings = generation.input().configured;

    for (std::size_t index = 0; index < 3; ++index) {
      bool rejected = false;

      try {
        generation.invoke(bindings[index].action, {});
      } catch (const std::exception&) {
        rejected = true;
      }

      check(rejected, "context mutation, recursive effects and exhausted callback budgets must fail before applying effects");
    }

    const auto recovered = generation.invoke(bindings[3].action, {});

    check(recovered.length == 1 && recovered.actions[0].kind == BindingActionKind::new_tab, "callback errors must leave the retained VM reusable");
    auto obsolete = bindings[3].action;

    ++obsolete.generation;
    bool rejected = false;

    try {
      generation.invoke(obsolete, {});
    } catch (const std::invalid_argument&) {
      rejected = true;
    }

    check(rejected, "callback references must be rejected across configuration generations");
  }

  void profilesThemesAndRejectedPreferences() {
    const auto configuration = read({.source = R"(return telar.config {api_version = 2, theme = "catppuccin", gui = {font = {size = 18, family = "JetBrains Mono"}, sidebar = {width = 350}, cursor = {blink = false}}, profiles = {large = {gui = {font = {size = 24}, max_fps = 120}}}})", .profile = "large"});
    constexpr float expected_font_size = 24;
    constexpr float expected_sidebar_width = 350;
    constexpr std::uint16_t expected_frame_cap = 120;
    constexpr auto expected_preset_background = Color::rgb(0x1e1e2e);

    check(configuration.font.size == expected_font_size && configuration.sidebar_width == expected_sidebar_width && !configuration.cursor_blink && configuration.max_fps == expected_frame_cap, "profile must override only its declared preferences");
    check(configuration.font.family.view() == "JetBrains Mono", "font name must outlive the Lua VM");
    check(configuration.theme.background == expected_preset_background, "preset must match its terminal theme");

    const auto custom = read({.source = R"(return {api_version = 2, theme = {base = "shade", terminal = {background = "#123456"}, colors = {accent = "#abcdef"}}})", .profile = {}});
    constexpr auto expected_custom_background = Color::rgb(0x123456);
    constexpr auto expected_custom_accent = Color::rgb(0xabcdef);

    check(custom.theme.background == expected_custom_background && custom.theme.accent == expected_custom_accent, "custom theme colors must apply");

    bool invalid = false;

    try {
      read({.source = "return {api_version = 2, gui = {font = {size = 0}}}", .profile = {}});
    } catch (const std::exception&) {
      invalid = true;
    }

    check(invalid, "out-of-range font sizes must be rejected");
    invalid = false;
    try {
      read({.source = "return {api_version = 2}", .profile = "missing"});
    } catch (const std::exception&) {
      invalid = true;
    }

    check(invalid, "unknown profiles must be rejected");
  }

  const telar::testing::Case case_history_preferences{"configuration.history_preferences", historyPreferences};
  const telar::testing::Case case_prompt_preferences{"configuration.prompt_preferences", promptPreferences};
  const telar::testing::Case case_prompt_bindings_value{"configuration.prompt_bindings_value", promptBindingsValue};
  const telar::testing::Case case_independent_background_opacity{"configuration.independent_background_opacity", independentBackgroundOpacity};
  const telar::testing::Case case_editor_preferences{"configuration.editor_preferences", editorPreferences};
  const telar::testing::Case case_window_title_preferences{"configuration.window_title_preferences", windowTitlePreferences};
  const telar::testing::Case case_sidebar_width_preferences{"configuration.sidebar_width_preferences", sidebarWidthPreferences};
  const telar::testing::Case case_keymap_profiles_and_callbacks{"configuration.keymap_profiles_and_callbacks", keymapProfilesAndCallbacks};
  const telar::testing::Case case_input_expressions{"configuration.input_expressions", inputExpressions};
  const telar::testing::Case case_invalid_callbacks_and_recovery{"configuration.invalid_callbacks_and_recovery", invalidCallbacksAndRecovery};
  const telar::testing::Case case_profiles_themes_and_rejected_preferences{"configuration.profiles_themes_and_rejected_preferences", profilesThemesAndRejectedPreferences};

}
