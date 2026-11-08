#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>
#include <algorithm>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "../core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include <cstdio>
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cstring>
#include <cmath>
#include <initializer_list>
#include <string>
#include <limits>
#include <bit>
#include <concepts>

#include "telar_client/serializers/telar_cells.hpp"
#include <charconv>
#include <system_error>
#include "telar_client/codecs/telar_value_codec.hpp"
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


import telar.gui.config.plugin_effects;
import telar.gui.config.generation;
import telar.gui.core.metrics;
import telar.gui.input.copy_pointer;
import telar.gui.input.key_encoder;
import telar.lua;

import telar.gui.config.gui_query;


namespace {

using namespace telar::gui;

struct ConfigurationExample {
  std::string_view source;
  std::string_view profile;
};

Configuration read(ConfigurationExample example) {
  SystemAllocator system;
  constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
  BudgetAllocator memory{system, allocation_budget};
  Configuration result;

  {
    telar::runtime::lua::Vm machine{memory};
    machine.execute(config_bootstrap, "@bootstrap.lua", 0);
    machine.execute(example.source, "@test.lua");
    result = ConfigurationReader::read(telar::runtime::lua::Value{machine.state(), -1, "config"}, example.profile);
  }

  if (memory.liveBytes() != 0) {
    throw std::runtime_error{"Configuration VM leaked injected allocations"};
  }

  return result;
}

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void historyPreferences() {
  const auto configuration = read({.source = R"(return {api_version = 2, client = {history = {show_agent_commands = true, enter = "run", match = "fts"}}, profiles = {paste = {client = {history = {enter = "paste"}}}}})", .profile = "paste"});
  require(configuration.history.show_agent_commands && !configuration.history.enter_runs && configuration.history.match_fts, "history profile fields must override independently and retain inherited choices");
  const auto defaults = read({.source = "return {api_version = 2}", .profile = {}});
  require(!defaults.history.show_agent_commands && !defaults.history.enter_runs && !defaults.history.match_fts, "history defaults must keep the human-only fuzzy paste behavior");

  constexpr auto invalid_sources = std::to_array<std::string_view>({R"(return {api_version = 2, client = {history = {enter = "exec"}}})", R"(return {api_version = 2, client = {history = {match = "regex"}}})", R"(return {api_version = 2, client = {history = {show_agent_commands = "yes"}}})"});
  for (const auto source : invalid_sources) {
    bool rejected = false;
    try {
      read({.source = source, .profile = {}});
    } catch (const std::exception &) {
      rejected = true;
    }

    require(rejected, "invalid history configuration must not be silently accepted");
  }
}

void independentBackgroundOpacity() {
  using Surface = BackgroundOpacity::Surface;
  const auto inherited = read({.source = R"(return {api_version=2,gui={window={background_opacity=0.75},opacity={sidebar=0.5,pane=0.25}},profiles={other={gui={window={background_opacity=1},opacity={topbar=0}}}}})", .profile = "other"});
  require(inherited.opacity.resolve(Surface::sidebar, inherited.background_opacity) == 0.5F && inherited.opacity.resolve(Surface::pane, inherited.background_opacity) == 0.25F, "profiles must preserve explicit surface opacities");
  require(inherited.opacity.resolve(Surface::topbar, inherited.background_opacity) == 0 && inherited.opacity.resolve(Surface::workspace, inherited.background_opacity) == 1, "unconfigured regions must inherit the adopted global value, including profile changes");
  require(inherited.opacity.minimum(inherited.background_opacity) == 0, "the native window must allow transparency when any region needs it");
  BackgroundOpacity opaque;
  opaque.overrides.fill(1.0F);
  require(opaque.minimum(0.25F) == 1, "fully opaque overrides must not retain unnecessary native transparency or blur");
  for (const auto *source : {R"(return {api_version=2,gui={opacity={pane=-0.01}}})", R"(return {api_version=2,gui={opacity={sidebar=1.01}}})", R"(return {api_version=2,gui={opacity={topbar=false}}})", R"(return {api_version=2,gui={opacity={workspace=0/0}}})", R"(return {api_version=2,gui={opacity={pane=math.huge}}})", R"(return {api_version=2,gui={opacity={unknown=0.5}}})"}) {
    bool rejected = false;
    try {
      read({.source = source, .profile = {}});
    } catch (const std::exception &) {
      rejected = true;
    }
    require(rejected, "invalid surface opacity must fail before adoption");
  }
}

void editorPreferences() {
  const auto inherited = read({.source = R"(return {api_version=2, client={editor="nvim"}, profiles={other={client={editor="/opt/Editor With Spaces"}}, inherited={client={pane_gaps=false}}}})", .profile = "inherited"});
  require(inherited.editor.view() == "nvim", "unrelated profile fields must preserve the configured editor");
  const auto overridden = read({.source = R"(return {api_version=2, client={editor="nvim"}, profiles={other={client={editor="/opt/Editor With Spaces"}}}})", .profile = "other"});
  require(overridden.editor.view() == "/opt/Editor With Spaces", "profile editors must override the inherited executable as one value");
  for (const auto *const source : {R"(return {api_version=2,client={editor=""}})", R"(return {api_version=2,client={editor="a\nb"}})", R"(return {api_version=2,client={editor=42}})"}) {
    bool rejected = false;
    try {
      read({.source = source, .profile = {}});
    } catch (const std::exception &) {
      rejected = true;
    }

    require(rejected, "invalid editor values must fail before configuration adoption");
  }
}

void windowTitlePreferences() {
  const auto inherited = read({.source = R"(return {api_version=2, client={window_title="{workspace}: {tab}"}, profiles={inherited={client={pane_gaps=false}}, replaced={client={window_title="{hostname}"}}, cleared={client={window_title=""}}}})", .profile = "inherited"});
  require(inherited.window_title.view() == "{workspace}: {tab}", "unrelated profile values must preserve the inherited title template after Lua teardown");
  const auto cleared = read({.source = R"(return {api_version=2,client={window_title="{tab}"},profiles={cleared={client={window_title=""}}}})", .profile = "cleared"});
  require(cleared.window_title.view().empty(), "an empty profile template must clear the inherited title");
  const auto replaced = read({.source = R"(return {api_version=2,client={window_title="{tab}"},profiles={replaced={client={window_title="{hostname}"}}}})", .profile = "replaced"});
  require(replaced.window_title.view() == "{hostname}", "a profile title must replace the inherited template");
  for (const auto *const source : {R"(return {api_version=2,client={window_title=42}})", R"(return {api_version=2,client={window_title="a\nb"}})", R"(return {api_version=2,client={window_title=string.rep("a",129)}})"}) {
    bool rejected = false;
    try {
      read({.source = source, .profile = {}});
    } catch (const std::exception &) {
      rejected = true;
    }

    require(rejected, "invalid title templates must fail before adoption");
  }
}

void sidebarWidthPreferences() {
  const auto defaults = read({.source = R"(return {api_version=2})", .profile = {}});
  require(defaults.sidebar_width_auto, "the sidebar fits its content unless a width is configured");
  const auto fixed = read({.source = R"(return {api_version=2,gui={sidebar={width=320}},profiles={automatic={gui={sidebar={width="auto"}}}}})", .profile = {}});
  require(!fixed.sidebar_width_auto && fixed.sidebar_width == 320, "a numeric width fixes the sidebar");
  const auto automatic = read({.source = R"(return {api_version=2,gui={sidebar={width=320}},profiles={automatic={gui={sidebar={width="auto"}}}}})", .profile = "automatic"});
  require(automatic.sidebar_width_auto, "a profile can return the sidebar to its automatic width");
  bool rejected = false;
  try {
    read({.source = R"(return {api_version=2,gui={sidebar={width="wide"}}})", .profile = {}});
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "a sidebar width is a number or \"auto\"");
}

void keymapProfilesAndCallbacks() {
  SystemAllocator system;
  constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
  BudgetAllocator memory{system, allocation_budget};
  {
    const ConfigurationSourceText source{
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
    ConfigurationGeneration generation{memory, source};
    const auto &input = generation.input();
    constexpr auto control = static_cast<unsigned>(KeyChord::Modifier::control);
    require(input.length == 2 && input.prefix == KeyChord{.key = KeyChord::Key::character, .character = 'o', .modifiers = control}, "profile prefixes must replace the default and inherited binding prefixes");
    require(input.configured[0].length == 3 && input.configured[0].keys[0] == input.prefix && input.configured[1].length == 1, "prefixed and global sequences must compile with their full declared length");
    constexpr std::uint64_t expected_timeout_ns = std::uint64_t{250} * 1000 * 1000;
    require(input.sequence_timeout_ns == expected_timeout_ns, "input sequence timeouts must use the selected profile");
    const BindingContext context{.active_tab_index = 1, .focused_pane_id = 3};
    const auto first = generation.invoke(input.configured[0].action, context);
    const auto second = generation.invoke(input.configured[0].action, context);
    require(first.length == 2 && first.actions[0].kind == BindingActionKind::toggle_sidebar && first.actions[1].parameter == 0 && second.actions[1].parameter == 1, "callback closures must survive configuration loading and retain validated action order");
  }

  require(memory.liveBytes() == 0, "retained configuration generations must release their VM through the injected allocator");
}

void inputExpressions() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
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
  ConfigurationGeneration generation{memory, source};
  const auto &bindings = generation.input().configured;
  const auto forward = generation.expression(bindings[0].action, {});
  require(forward.kind == InputExpression::Kind::forward && forward.length == bindings[0].length && forward.keys[0] == generation.input().prefix, "forward expressions must replay the entire effective trigger including its prefix");
  const auto keys = generation.expression(bindings[1].action, {});
  require(keys.kind == InputExpression::Kind::keys && keys.length == 3 && keys.keys[1].key == KeyChord::Key::enter, "key expressions must parse complete named and Unicode chords");
  const auto paste = generation.expression(bindings[2].action, {});
  require(paste.kind == InputExpression::Kind::paste && paste.paste.view() == "one\ntwo", "paste expressions must own the complete Lua result");
  require(generation.expression(bindings[3].action, {}).kind == InputExpression::Kind::consume, "consume expressions must generate no input");
}

void invalidCallbacksAndRecovery() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
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
  ConfigurationGeneration generation{memory, source};
  const auto &bindings = generation.input().configured;
  for (std::size_t index = 0; index < 3; ++index) {
    bool rejected = false;
    try {
      generation.invoke(bindings[index].action, {});
    } catch (const std::exception &) {
      rejected = true;
    }

    require(rejected, "context mutation, recursive effects and exhausted callback budgets must fail before applying effects");
  }

  const auto recovered = generation.invoke(bindings[3].action, {});
  require(recovered.length == 1 && recovered.actions[0].kind == BindingActionKind::new_tab, "callback errors must leave the retained VM reusable");
  auto obsolete = bindings[3].action;
  ++obsolete.generation;
  bool rejected = false;
  try {
    generation.invoke(obsolete, {});
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected, "callback references must be rejected across configuration generations");
}

}

int main() {
  try {
    historyPreferences();
    independentBackgroundOpacity();
    editorPreferences();
    windowTitlePreferences();
    sidebarWidthPreferences();
    keymapProfilesAndCallbacks();
    inputExpressions();
    invalidCallbacksAndRecovery();
    const auto configuration = read({.source = R"(return telar.config {api_version = 2, theme = "catppuccin", gui = {font = {size = 18, family = "JetBrains Mono"}, sidebar = {width = 350}, cursor = {blink = false}}, profiles = {large = {gui = {font = {size = 24}, max_fps = 120}}}})", .profile = "large"});
    constexpr float expected_font_size = 24;
    constexpr float expected_sidebar_width = 350;
    constexpr std::uint16_t expected_frame_cap = 120;
    constexpr auto expected_preset_background = Color::rgb(0x1e1e2e);
    require(configuration.font.size == expected_font_size && configuration.sidebar_width == expected_sidebar_width && !configuration.cursor_blink && configuration.max_fps == expected_frame_cap, "profile must override only its declared preferences");
    require(configuration.font.family.view() == "JetBrains Mono", "font name must outlive the Lua VM");
    require(configuration.theme.background == expected_preset_background, "preset must match its terminal theme");

    const auto custom = read({.source = R"(return {api_version = 2, theme = {base = "shade", terminal = {background = "#123456"}, colors = {accent = "#abcdef"}}})", .profile = {}});
    constexpr auto expected_custom_background = Color::rgb(0x123456);
    constexpr auto expected_custom_accent = Color::rgb(0xabcdef);
    require(custom.theme.background == expected_custom_background && custom.theme.accent == expected_custom_accent, "custom theme colors must apply");

    bool invalid = false;
    try {
      read({.source = "return {api_version = 2, gui = {font = {size = 0}}}", .profile = {}});
    } catch (const std::exception &) {
      invalid = true;
    }

    require(invalid, "out-of-range font sizes must be rejected");
    invalid = false;
    try {
      read({.source = "return {api_version = 2}", .profile = "missing"});
    } catch (const std::exception &) {
      invalid = true;
    }

    require(invalid, "unknown profiles must be rejected");
    std::puts("gui-config: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-config: " << error.what() << '\n';

    return 1;
  }
}
