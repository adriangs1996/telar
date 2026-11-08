module;
#include <cstdlib>
#include <new>

#include <cstdint>
#include <cstddef>
#include <cinttypes>
#include <cstdio>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <cstring>
#include <cmath>



#include "gui_config_bootstrap.hpp"

#include <limits.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <ghostty/vt/unicode.h>
#include "tbc/view.hpp"

export module telar.gui.config.generation;

import std;

export import telar.gui.config.plugin_query;
export import telar.config;
export import telar.lua;
export import telar.plugins;


export import telar.gui.input.copy_pointer;


export import telar.gui.input.key_encoder;
export import telar.gui.input.configuration;

export import telar.gui.config.gui_query;


export import telar.gui.presentation.suggestion_geometry;


export import telar.gui.core.metrics;


export import telar.gui.config.plugin_effects;
export import telar.gui.components.configuration;
export import telar.gui.components.builtin_content;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: config/action_description_reader.cppm
export {
namespace telar::gui {

class ActionDescriptionReader {
public:
  inline static ExtendedActionDescription read(const runtime::lua::Value &value, const runtime::config::ClientDefinitions &definitions) {
    const auto kind = value.field("kind");
    const auto name = kind.string();
    if (name == "notification") {
      return notification(value);
    }

    if (name == "plugin") {
      return PluginActionDescription{.plugin = runtime::plugins::stableId(value.field("plugin").string()), .action = runtime::plugins::stableId(value.field("action").string())};
    }

    const bool panel = name == "open-panel";
    const auto selected = value.field(panel ? "panel" : "pick");
    const auto index = definitions.index(panel ? "panels" : "picks", selected.string());
    if (!index) {
      selected.fail("names an unknown client definition");
    }

    return DefinitionActionDescription{.kind = panel ? DefinitionActionDescription::Kind::panel : DefinitionActionDescription::Kind::pick, .index = *index};
  }

  inline static NotificationActionDescription notification(const runtime::lua::Value &value) {
    NotificationActionDescription result;
    result.title.assign(runtime::utf8Prefix(value.field("title").string(), max_notification_title_bytes));
    const auto body = value.field("body");
    if (body.present()) {
      result.message.assign(runtime::utf8Prefix(body.string(), max_notification_message_bytes));
    }

    const auto level = value.field("level");
    if (level.present()) {
      constexpr std::array names{"info", "success", "warning", "failure"};
      for (std::size_t index = 0; index < names.size(); ++index) {
        if (level.string() == names[index]) {
          result.level = static_cast<NotificationLevel>(index);
        }
      }
    }

    result.duration_ms = static_cast<std::uint32_t>(value.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms));
    constexpr std::array targets{"pane_id", "tab_id", "workspace_id"};
    for (std::size_t index = 0; index < targets.size(); ++index) {
      const auto target = value.field(targets[index]);
      if (target.present()) {
        result.target = {.kind = static_cast<NotificationTarget::Kind>(index + 1), .id = static_cast<std::uint64_t>(target.integer())};
      }
    }

    return result;
  }
};

}
}

// Interface: config/action_reader.cppm
export {
namespace telar::gui {

class BindingActionReader {
public:
  inline explicit BindingActionReader(lua_State &state, const runtime::config::RetainedActionValidator &validator, runtime::config::RetainedCommandTabRegistry &commands, std::uint64_t generation)
      : state_(state),
        validator_(validator),
        commands_(commands),
        generation_(generation) {}

  [[nodiscard]] inline std::optional<BindingAction> read(const runtime::lua::Value &value, bool expression = false) const {
    if (!validator_.validate(value, expression)) {
      return {};
    }

    if (value.is(LUA_TFUNCTION)) {
      return referenced(value, expression ? BindingActionKind::expression : BindingActionKind::callback);
    }

    if (value.is(LUA_TSTRING)) {
      return builtin(value);
    }

    const auto kind = value.field("kind");
    const auto name = kind.string();
    if (const auto action = builtinBindingAction(name)) {
      return action;
    }

    if (name == "select-tab" || name == "select-workspace") {
      return BindingAction{.kind = name == "select-tab" ? BindingActionKind::select_tab : BindingActionKind::select_workspace, .parameter = static_cast<std::int32_t>(value.field("index").integer() - 1)};
    }

    if (name == "select-tab-offset") {
      return BindingAction{.kind = BindingActionKind::select_tab_offset, .parameter = static_cast<std::int32_t>(value.field("offset").integer())};
    }

    if (name == "command-tab") {
      return command(value);
    }

    if (name == "notification" || name == "open-panel" || name == "pick" || name == "plugin") {
      return referenced(value, BindingActionKind::extended);
    }

    return directional(value, name);
  }

private:
  [[nodiscard]] inline BindingAction command(const runtime::lua::Value &value) const {
    const auto command = value.field("command");
    const auto count = command.listLength();
    std::array<std::string_view, runtime::config::CommandTabView::maximum_arguments> arguments{};
    if (count == 0 || count > arguments.size()) {
      command.fail("has an invalid number of command arguments");
    }

    for (std::size_t index = 0; index < count; ++index) {
      arguments[index] = command.element(static_cast<lua_Integer>(index) + 1).string();
    }

    const auto label = value.field("label");
    runtime::config::LimitNotices limits;
    const auto reference = commands_.keepReference(std::span{arguments}.first(count), label.is(LUA_TSTRING) ? label.string() : std::string_view{}, limits);
    if (!reference) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return commandTabAction(*reference, generation_);
  }

  inline static BindingAction builtin(const runtime::lua::Value &value) {
    if (const auto action = builtinBindingAction(value.string())) {
      return *action;
    }

    value.fail("names an unknown binding action");
  }

  inline static BindingAction directional(const runtime::lua::Value &value, std::string_view name) {
    constexpr auto stems = std::to_array<std::pair<std::string_view, std::string_view>>({
        {"scroll-pane", "scroll-pane-"},
        {"split-pane", "split-"},
        {"focus-pane", "focus-"},
        {"navigate-pane", "navigate-"},
        {"resize-pane", "resize-"},
        {"resize-sidebar", "resize-sidebar-"},
        {"move-tab", "move-tab-"},
    });
    const auto *const found = std::ranges::find(stems, name, &decltype(stems)::value_type::first);
    if (found == stems.end()) {
      value.fail("names an unknown binding action");
    }

    const auto direction = value.field("direction");
    const auto suffix = direction.string();
    constexpr std::size_t name_capacity = 64;
    std::array<char, name_capacity> combined{};
    if (found->second.size() + suffix.size() > combined.size()) {
      direction.fail("names an invalid direction");
    }

    const auto copied = std::ranges::copy(found->second, combined.begin());
    std::ranges::copy(suffix, copied.out);
    const auto action = builtinBindingAction({combined.data(), found->second.size() + suffix.size()});
    if (!action) {
      direction.fail("names an invalid direction");
    }

    return *action;
  }

  [[nodiscard]] inline BindingAction referenced(const runtime::lua::Value &value, BindingActionKind kind) const {
    value.pushCopy();

    return {.kind = kind, .reference = luaL_ref(&state_, LUA_REGISTRYINDEX), .generation = generation_};
  }

  lua_State &state_;
  const runtime::config::RetainedActionValidator &validator_;
  runtime::config::RetainedCommandTabRegistry &commands_;
  std::uint64_t generation_;
};

}
}

// Interface: config/binding_reader.cppm
export {
namespace telar::gui {

template <typename Reader>
concept BindingActionSource = requires(const Reader &reader, const runtime::lua::Value &value) {
  { reader.read(value, false) } -> std::same_as<std::optional<BindingAction>>;
};

class BindingReader {
public:
  template <BindingActionSource Actions>
  inline static void apply(const runtime::lua::Value &client, InputConfiguration &input, const Actions &actions) {
    if (!client.present()) {
      return;
    }

    const auto prefix = client.field("prefix");
    if (prefix.present()) {
      input.setPrefix(runtime::config::KeyChordValidator::parse(prefix));
    }

    const auto options = client.field("input");
    if (options.present()) {
      options.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
      constexpr std::uint64_t minimum_timeout_ms = 10;
      constexpr std::uint64_t maximum_timeout_ms = 10'000;
      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      input.sequence_timeout_ns = options.field("sequence_timeout_ms").boundedInteger(input.sequence_timeout_ns / nanoseconds_per_millisecond, minimum_timeout_ms, maximum_timeout_ms) * nanoseconds_per_millisecond;
    }

    const auto bindings = client.field("keybindings");
    if (!bindings.present()) {
      return;
    }

    const auto count = bindings.listLength();
    input.length = 0;
    input.dropped = count - std::min(count, BindingLimits::bindings);
    for (std::size_t index = 0; index < std::min(count, BindingLimits::bindings); ++index) {
      const auto value = bindings.element(static_cast<lua_Integer>(index) + 1);
      auto binding = read(value, input.prefix);
      const auto action = actions.read(value.field("action"), value.field("expression").boolean(false));
      if (action) {
        binding.action = *action;
        input.configured[input.length++] = binding;
      }
    }
  }

private:
  inline static KeyBinding<BindingAction> read(const runtime::lua::Value &value, KeyChord prefix) {
    value.onlyFields({"keys", "action", "expression", "prefixed"});
    const auto prefixed = value.field("prefixed");
    if (!prefixed.present()) {
      prefixed.fail("must be a boolean");
    }

    KeyBinding<BindingAction> binding{.prefixed = prefixed.boolean(false)};
    const auto offset = static_cast<std::size_t>(binding.prefixed);
    const auto keys = value.field("keys");
    const auto count = keys.listLength();
    if (count == 0 || count > BindingLimits::keys - offset) {
      keys.fail("has an invalid number of binding keys");
    }

    if (binding.prefixed) {
      binding.keys[0] = prefix;
    }

    binding.length = count + offset;
    for (std::size_t index = 0; index < count; ++index) {
      binding.keys[index + offset] = runtime::config::KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
    }

    return binding;
  }
};

}
}

// Interface: config/themes.cppm
export {
namespace telar::gui {

inline std::string_view canonicalThemeName(std::string_view name) noexcept {
  if (name == "osaka-jade" || name == "osaka_jade" || name == "osakajade") {
    return "shade";
  }
  if (name == "catppuccin-mocha" || name == "mocha") {
    return "catppuccin";
  }
  if (name == "tokyonight" || name == "tokyo_night") {
    return "tokyo-night";
  }
  if (name == "kanagawa-wave" || name == "kanagawa_wave") {
    return "kanagawa";
  }
  if (name == "kanagawa_dragon") {
    return "kanagawa-dragon";
  }
  if (name == "default") {
    return "terminal";
  }

  return name;
}

inline ThemeValues themeValuesByName(std::string_view name) {
  constexpr std::size_t maximum_name_bytes = 64;
  if (name.size() > maximum_name_bytes) {
    throw std::invalid_argument{"GUI theme name exceeds capacity"};
  }

  std::array<char, maximum_name_bytes> lowercase{};
  std::ranges::transform(name, lowercase.begin(), [](char character) {
    return character >= 'A' && character <= 'Z' ? static_cast<char>(character + 'a' - 'A') : character;
  });
  const auto canonical = canonicalThemeName({lowercase.data(), name.size()});
  const auto *const found = std::ranges::find_if(theme_presets, [&](const auto &preset) {
    return preset.name == canonical;
  });
  if (found == theme_presets.end()) {
    throw std::invalid_argument{"Unknown GUI theme"};
  }

  return found->values;
}

inline Theme themeByName(std::string_view name) {
  return projectTheme(themeValuesByName(name));
}

}
}

// Interface: config/theme_reader.cppm
export {
namespace telar::gui {

class ThemeReader {
  using Value = runtime::lua::Value;

public:
  inline static void apply(const Value &root, ThemeSelection &selection) {
    applyTheme(root.field("theme"), selection.base);
    const auto client = root.field("client");
    if (!client.present()) {
      return;
    }

    applyTheme(client.field("theme"), selection.base);
    const auto appearance = client.field("appearance");
    if (!appearance.present()) {
      return;
    }

    applyVariant(appearance.field("light"), selection.light, selection.base);
    applyVariant(appearance.field("dark"), selection.dark, selection.base);
  }

private:
  inline static CellColor color(const Value &value) {
    const auto text = value.string();
    if (text == "default") {
      return {};
    }

    constexpr std::size_t rgb_text_length = 7;
    if (text.size() != rgb_text_length || text.front() != '#') {
      value.fail("must be an RGB hexadecimal color");
    }

    std::uint32_t rgb = 0;
    constexpr int hexadecimal_base = 16;
    const auto parsed = std::from_chars(text.data() + 1, text.data() + text.size(), rgb, hexadecimal_base);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
      value.fail("must be an RGB hexadecimal color");
    }

    constexpr unsigned channel_bits = 8;

    return {.kind = CellColor::Kind::rgb, .channels = {static_cast<Byte>(rgb >> (channel_bits * 2)), static_cast<Byte>(rgb >> channel_bits), static_cast<Byte>(rgb)}};
  }

  inline static void applyVariant(const Value &value, std::optional<ThemeValues> &variant, const ThemeValues &base) {
    if (!value.present()) {
      return;
    }

    auto result = variant.value_or(base);
    applyTheme(value, result);
    variant = result;
  }

  inline static void applyTheme(const Value &value, ThemeValues &theme) {
    if (!value.present()) {
      return;
    }

    if (value.is(LUA_TSTRING)) {
      theme = themeValuesByName(value.string());

      return;
    }

    const auto base = value.field("base");
    if (base.present()) {
      theme = themeValuesByName(base.string());
    }

    const auto colors = value.field("colors");
    if (colors.present()) {
      for (std::size_t index = 0; index < palette_names.size(); ++index) {
        const auto entry = colors.field(palette_names[index]);
        if (entry.present()) {
          theme.palette[index] = color(entry);
        }
      }
    }

    applyTerminal(value.field("terminal"), theme.terminal);
    applySyntax(value.field("syntax"), theme);
  }

  inline static void applyRgb(const Value &value, ThemeRgb &destination) {
    if (!value.present()) {
      return;
    }

    const auto selected = color(value);
    if (selected.kind != CellColor::Kind::rgb) {
      value.fail("must be an explicit RGB color");
    }

    destination = selected.channels;
  }

  inline static void applyOptionalRgb(const Value &value, std::optional<ThemeRgb> &destination) {
    if (value.present()) {
      ThemeRgb result{};
      applyRgb(value, result);
      destination = result;
    }
  }

  inline static void applyTerminal(const Value &value, TerminalThemeValues &terminal) {
    if (!value.present()) {
      return;
    }

    applyRgb(value.field("foreground"), terminal.foreground);
    applyRgb(value.field("background"), terminal.background);
    applyOptionalRgb(value.field("cursor_color"), terminal.cursor_color);
    applyOptionalRgb(value.field("cursor_text_color"), terminal.cursor_text_color);
    const auto palette = value.field("palette");
    if (palette.present()) {
      for (std::size_t index = 0; index < terminal.palette.size(); ++index) {
        applyRgb(palette.element(static_cast<lua_Integer>(index) + 1), terminal.palette[index]);
      }
    }
  }

  inline static void applySyntax(const Value &value, ThemeValues &theme) {
    if (!value.present()) {
      return;
    }

    for (std::size_t index = 0; index < syntax_names.size(); ++index) {
      const auto entry = value.field(syntax_names[index]);
      if (!entry.present()) {
        continue;
      }

      auto style = theme.syntaxStyle(static_cast<SyntaxRole>(index));
      if (entry.is(LUA_TTABLE)) {
        const auto foreground = entry.field("fg");
        if (foreground.present()) {
          style.color = color(foreground);
        }

        style.italic = entry.field("italic").boolean(style.italic);
        style.bold = entry.field("bold").boolean(style.bold);
      } else {
        style.color = color(entry);
      }

      theme.syntax_styles[index] = style;
    }
  }
};

}
}

// Interface: config/reader.cppm
export {
namespace telar::gui {

class ConfigurationReader {
public:
  inline static Configuration read(const runtime::lua::Value &root, std::string_view profile) {
    root.onlyFields({"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"});
    if (root.field("api_version").integer() != 2) {
      root.fail("requires api_version = 2");
    }

    Configuration result;
    result.themes.base = default_theme_values;
    apply(root, result);

    if (!profile.empty()) {
      const auto profiles = root.field("profiles");
      if (!profiles.present()) {
        profiles.fail("does not define the selected profile");
      }

      const auto selected = profiles.entry(profile);
      if (!selected.present()) {
        selected.fail("is not defined");
      }

      apply(selected.as("config"), result);
    }

    result.theme = projectTheme(result.themes.base);

    return result;
  }

private:
  using Value = runtime::lua::Value;

  inline static void apply(const Value &root, Configuration &configuration) {
    runtime::config::ThemeValidator::selection(root);
    ThemeReader::apply(root, configuration.themes);
    client(root.field("client"), configuration);

    const auto gui = root.field("gui");
    runtime::config::GuiValidator::validate(gui);
    if (!gui.present()) {
      return;
    }

    font(gui.field("font"), configuration.font);
    const auto cursor = gui.field("cursor");
    if (cursor.present()) {
      const auto style = cursor.field("style");
      if (style.present()) {
        configuration.cursor = cursorShape(style.string());
      }

      configuration.cursor_blink = cursor.field("blink").boolean(configuration.cursor_blink);
      configuration.blink_interval = std::chrono::milliseconds{cursor.field("blink_interval_ms").boundedInteger(configuration.blink_interval.count(), Configuration::minimum_blink_interval.count(), Configuration::maximum_blink_interval.count())};
    }

    window(gui.field("window"), configuration);
    const auto opacity = gui.field("opacity");
    if (opacity.present()) {
      for (std::size_t index = 0; index < BackgroundOpacity::names.size(); ++index) {
        const auto value = opacity.field(BackgroundOpacity::names[index]);
        if (value.present()) {
          configuration.opacity.overrides[index] = static_cast<float>(value.boundedNumber(1, 0, 1));
        }
      }
    }
    const auto chrome = gui.field("chrome");
    if (chrome.present()) {
      configuration.chrome_scale = static_cast<float>(chrome.field("scale").boundedNumber(configuration.chrome_scale, Configuration::minimum_chrome_scale, Configuration::maximum_chrome_scale));
    }

    const auto sidebar = gui.field("sidebar");
    if (sidebar.present()) {
      configuration.sidebar_width = static_cast<float>(sidebar.field("width").boundedNumber(configuration.sidebar_width, Configuration::minimum_sidebar_width, Configuration::maximum_sidebar_width));
    }

    const auto fps = gui.field("max_fps");
    if (fps.present()) {
      configuration.max_fps = static_cast<std::uint16_t>(fps.boundedInteger(configuration.max_fps, Configuration::minimum_fps, Configuration::maximum_fps));
    }
  }

  inline static void client(const Value &table, Configuration &configuration) {
    if (!table.present()) {
      return;
    }

    const auto sidebar = table.field("sidebar");
    if (sidebar.present()) {
      configuration.sidebar_visible = sidebar.field("visible").boolean(configuration.sidebar_visible);
    }

    configuration.pane_gaps = table.field("pane_gaps").boolean(configuration.pane_gaps);
    const auto editor = table.field("editor");
    if (editor.present()) {
      DisplayText16<Configuration::maximum_editor_bytes, false>::validate(editor.string());
      configuration.editor.assign(editor.string());
    }

    const auto window_title = table.field("window_title");
    if (window_title.present()) {
      DisplayText16<Configuration::maximum_window_title_bytes, true>::validate(window_title.string());
      configuration.window_title.assign(window_title.string());
    }

    history(table.field("history"), configuration.history);
    sound(table.field("sound"), configuration.sound);
    const auto notifications = table.field("notifications");
    if (notifications.present()) {
      notifications.onlyFields({"delivery"});
      const auto delivery = notifications.field("delivery");
      runtime::config::optionalChoice(delivery, {"telar", "system", "terminal"});
      if (delivery.present() && delivery.string() != "terminal") {
        configuration.notification_delivery = delivery.string() == "system" ? NotificationDelivery::system : NotificationDelivery::telar;
      }
    }
  }

  inline static void sound(const Value &table, SoundPolicy &policy) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "ready", "needs_input"});
    policy.enabled = table.field("enabled").boolean(policy.enabled);
    policy.ready = table.field("ready").boolean(policy.ready);
    policy.needs_input = table.field("needs_input").boolean(policy.needs_input);
  }

  inline static void history(const Value &table, HistoryConfiguration &history) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"show_agent_commands", "enter", "match"});
    history.show_agent_commands = table.field("show_agent_commands").boolean(history.show_agent_commands);
    const auto enter = table.field("enter");
    const auto match = table.field("match");
    runtime::config::optionalChoice(enter, {"paste", "run"});
    runtime::config::optionalChoice(match, {"fuzzy", "fts"});
    if (enter.present()) {
      history.enter_runs = enter.string() == "run";
    }

    if (match.present()) {
      history.match_fts = match.string() == "fts";
    }
  }

  inline static void font(const Value &table, FontConfiguration &font) {
    if (!table.present()) {
      return;
    }

    const auto family = table.field("family");
    const auto style = table.field("style");
    if (family.present()) {
      font.family.assign(family.string());
    }

    if (style.present()) {
      font.style.assign(style.string());
    }

    font.size = static_cast<float>(table.field("size").boundedNumber(font.size, FontConfiguration::minimum_size, FontConfiguration::maximum_size));
    font.line_height = static_cast<float>(table.field("line_height").boundedNumber(font.line_height, FontConfiguration::minimum_line_height, FontConfiguration::maximum_line_height));
    font.letter_spacing = static_cast<float>(table.field("letter_spacing").boundedNumber(font.letter_spacing, FontConfiguration::minimum_letter_spacing, FontConfiguration::maximum_letter_spacing));
    font.thicken = table.field("thicken").boolean(font.thicken);
    font.thicken_strength = static_cast<std::uint8_t>(table.field("thicken_strength").boundedInteger(font.thicken_strength, 0, FontConfiguration::maximum_thicken_strength));
  }

  inline static void window(const Value &table, Configuration &configuration) {
    if (!table.present()) {
      return;
    }

    configuration.background_opacity = static_cast<float>(table.field("background_opacity").boundedNumber(configuration.background_opacity, 0, 1));
    const auto titlebar = table.field("titlebar");
    if (titlebar.present()) {
      configuration.titlebar = titlebar.boolean(true);
    }

    const auto blur = table.field("background_blur");
    if (blur.present()) {
      if (blur.is(LUA_TBOOLEAN)) {
        configuration.background_blur = blur.boolean(false) ? Configuration::default_background_blur : 0;
      } else {
        configuration.background_blur = static_cast<std::uint8_t>(blur.boundedInteger(configuration.background_blur, 0, Configuration::maximum_background_blur));
      }
    }

    const auto padding = table.field("padding");
    if (padding.present()) {
      configuration.padding_x = static_cast<float>(padding.field("x").boundedNumber(configuration.padding_x, 0, Configuration::maximum_padding));
      configuration.padding_y = static_cast<float>(padding.field("y").boundedNumber(configuration.padding_y, 0, Configuration::maximum_padding));
    }
  }

  inline static CursorShape cursorShape(std::string_view name) noexcept {
    if (name == "bar") {
      return CursorShape::bar;
    }

    if (name == "underline") {
      return CursorShape::underline;
    }

    if (name == "hollow") {
      return CursorShape::hollow;
    }

    return CursorShape::block;
  }
};

}
}

// Interface: config/recording_action_reader.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class RecordingActionReader {
public:
  inline explicit RecordingActionReader(const BindingActionReader &reader, ActionDescriptions<Memory> &descriptions, const runtime::config::ClientDefinitions &definitions)
      : reader_(reader),
        descriptions_(descriptions),
        definitions_(definitions) {}

  [[nodiscard]] inline std::optional<BindingAction> read(const runtime::lua::Value &value, bool expression = false) const {
    auto action = reader_.read(value, expression);
    if (!action) {
      return {};
    }

    if (action->kind == BindingActionKind::callback || action->kind == BindingActionKind::expression) {
      action->parameter = descriptions_.registerCallback();
    } else if (action->kind == BindingActionKind::extended) {
      action->parameter = descriptions_.retain(ActionDescriptionReader::read(value, definitions_));
    }

    return action;
  }

private:
  const BindingActionReader &reader_;
  ActionDescriptions<Memory> &descriptions_;
  const runtime::config::ClientDefinitions &definitions_;
};

}
}

// Interface: config/generation.cppm
export {
namespace telar::gui {

// Interface: config/element_reader.cppm
// Turns what a slot function returned into elements. It runs on the Lua thread; actions are
// resolved as they are read and functions are handed to `callback`, so the result needs no VM.
template <Allocator Memory, typename Action, typename Callback>
class ElementReader {
public:
  using Element = components::Element;
  using Kind = components::ElementKind;
  using Value = runtime::lua::Value;

  inline ElementReader(RenderedElements<Memory> &output, const Action &action, const Callback &callback) noexcept
      : output_(output),
        action_(action),
        callback_(callback) {}

  inline void read(const Value &root) {
    if (root.is(LUA_TTABLE) && !root.field("ui").present()) {
      Element row;
      const auto index = append(root, row);
      children(root, index, 1);

      return;
    }

    element(root, Element::none, 0);
  }

private:
  inline void element(const Value &value, std::uint32_t parent, unsigned depth) {
    if (!value.present()) {
      return;
    }

    if (depth > Element::maximum_depth) {
      value.fail("nests elements deeper than 32 levels");
    }

    if (value.is(LUA_TSTRING)) {
      Element label;
      label.kind = Kind::label;
      label.parent = parent;
      label.text = text(value);
      static_cast<void>(append(value, label));

      return;
    }

    if (!value.is(LUA_TTABLE)) {
      value.fail("must be text, an element or a list of elements");
    }

    if (!value.field("ui").present()) {
      // A list inside a container flattens into it.
      children(value, parent, depth + 1);

      return;
    }

    const auto name = value.field("ui").string();
    const auto *const found = std::ranges::find(components::element_kind_names, name);
    if (found == components::element_kind_names.end()) {
      value.field("ui").fail("names an unknown element");
    }

    Element result;
    result.kind = static_cast<Kind>(found - components::element_kind_names.begin());
    result.parent = parent;
    fields(value, result);
    const auto index = append(value, result);
    if (result.kind == Kind::row || result.kind == Kind::column || result.kind == Kind::stack) {
      children(value, index, depth + 1);
    }
  }

  inline void children(const Value &value, std::uint32_t parent, unsigned depth) {
    const auto count = value.listLength();
    for (std::size_t index = 0; index < count; ++index) {
      element(value.element(static_cast<lua_Integer>(index) + 1), parent, depth);
    }
  }

  inline std::uint32_t append(const Value &value, const Element &element) {
    if (output_.elements.size() == Element::maximum_elements) {
      value.fail("exceeds 4096 elements");
    }

    output_.elements.push_back(element);

    return static_cast<std::uint32_t>(output_.elements.size() - 1);
  }

  static constexpr std::array<std::string_view, 27> layout_fields{"ui", "id", "width", "height", "min_width", "max_width", "min_height", "max_height", "grow", "align_self", "x", "y", "rotation", "scale", "opacity", "z", "background", "border", "radius", "padding", "shadow", "clip", "on_click", "url", "tooltip", "hover", "transition"};

  inline void fields(const Value &value, Element &element) {
    switch (element.kind) {
    case Kind::row:
    case Kind::column:
    case Kind::stack:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"gap", "align", "justify"})}, true);
      element.gap = length(value.field("gap"), 0);
      element.align = choice(value.field("align"), {"start", "center", "end", "stretch"}, 0);
      element.justify = choice(value.field("justify"), {"start", "center", "end", "between"}, 0);
      break;
    case Kind::spacer:
      value.onlyFields(std::span<const std::string_view>{layout_fields});
      element.grow = 1;
      break;
    case Kind::label:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"text", "size", "bold", "italic", "color", "tone", "max_lines"})});
      element.text = text(value.field("text"));
      typography(value, element);
      element.max_lines = static_cast<std::uint8_t>(value.field("max_lines").boundedInteger(1, 1, 64));
      break;
    case Kind::icon:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"name", "glyph", "size", "color", "tone"})});
      element.named = value.field("name").present();
      element.text = text(element.named ? value.field("name") : value.field("glyph"));
      if (element.text.length == 0) {
        value.fail("requires an icon name or a glyph");
      }
      typography(value, element);
      break;
    case Kind::mark:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"name"})});
      runtime::config::uiMark(value.field("name"));
      element.text = text(value.field("name"));
      break;
    case Kind::badge:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"text", "tone", "color", "size"})});
      element.text = text(value.field("text"));
      typography(value, element);
      break;
    case Kind::tile:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"program", "size"})});
      element.text = text(value.field("program"));
      element.size = length(value.field("size"), 0);
      break;
    case Kind::canvas:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"ops", "label"})});
      element.text = text(value.field("label"));
      canvas(value.field("ops"), element);
      break;
    case Kind::builtin: {
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"name"})});
      const auto name = value.field("name").string();
      if (std::ranges::find(components::builtin_names, name) == components::builtin_names.end()) {
        value.field("name").fail("names an unknown built-in piece");
      }

      element.text = text(value.field("name"));
    } break;
    case Kind::elapsed:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"since", "size", "bold", "color", "tone"})});
      element.since = value.field("since").integer();
      typography(value, element);
      break;
    case Kind::clock:
      value.onlyFields(std::span<const std::string_view>{combined(layout_fields, {"format", "size", "bold", "color", "tone"})});
      element.text = value.field("format").present() ? text(value.field("format")) : store("%H:%M", value);
      typography(value, element);
      break;
    }

    box(value, element);
  }

  inline void box(const Value &value, Element &element) {
    if (const auto id = value.field("id"); id.present()) {
      element.key = text(id);
    }

    element.width = length(value.field("width"), -1);
    element.height = length(value.field("height"), -1);
    element.min_width = length(value.field("min_width"), 0);
    element.max_width = length(value.field("max_width"), -1);
    element.min_height = length(value.field("min_height"), 0);
    element.max_height = length(value.field("max_height"), -1);
    element.grow = static_cast<float>(value.field("grow").boundedNumber(element.grow, 0, 1000));
    if (const auto align = value.field("align_self"); align.present()) {
      element.align_self = choice(align, {"start", "center", "end", "stretch"}, 0);
    }

    element.x = offset(value.field("x"));
    element.y = offset(value.field("y"));
    element.rotation = static_cast<float>(value.field("rotation").boundedNumber(0, -3600, 3600));
    element.scale = static_cast<float>(value.field("scale").boundedNumber(1, 0, 16));
    element.opacity = static_cast<float>(value.field("opacity").boundedNumber(1, 0, 1));
    element.z = static_cast<std::int16_t>(std::lround(value.field("z").boundedNumber(0, -1000, 1000)));
    element.background = color(value.field("background"));
    element.radius = length(value.field("radius"), 0);
    element.shadow = value.field("shadow").boolean(false);
    element.clip = value.field("clip").boolean(false);
    padding(value.field("padding"), element);
    if (const auto border = value.field("border"); border.present()) {
      if (border.is(LUA_TTABLE)) {
        border.onlyFields({"color", "width"});
        element.border = color(border.field("color"));
        element.border_width = length(border.field("width"), 1);
      } else {
        element.border = color(border);
        element.border_width = 1;
      }
    }

    if (const auto hover = value.field("hover"); hover.present()) {
      hover.onlyFields({"background"});
      element.hover = color(hover.field("background"));
    }

    if (const auto transition = value.field("transition"); transition.present()) {
      if (transition.is(LUA_TTABLE)) {
        transition.onlyFields({"duration", "easing"});
        element.transition_ms = static_cast<std::uint16_t>(transition.field("duration").boundedInteger(220, 0, 10000));
        element.easing = choice(transition.field("easing"), {"ease_out", "linear", "ease_in_out"}, 0);
      } else {
        element.transition_ms = static_cast<std::uint16_t>(transition.boundedInteger(220, 0, 10000));
      }
    }

    if (const auto tooltip = value.field("tooltip"); tooltip.present()) {
      element.tooltip = text(tooltip);
    }

    if (const auto url = value.field("url"); url.present()) {
      const auto link = url.string();
      constexpr std::size_t maximum_url_bytes = 1024;
      if (link.size() > maximum_url_bytes || link.contains(' ') || (!link.starts_with("https://") && !link.starts_with("http://"))) {
        url.fail("must be an http or https address");
      }

      element.url = text(url);
    }

    if (const auto click = value.field("on_click"); click.present()) {
      if (click.is(LUA_TFUNCTION)) {
        element.callback = callback_(click);
      } else if (auto resolved = action_(click)) {
        if (output_.bindings.size() == Element::maximum_actions) {
          click.fail("exceeds 1024 click actions");
        }

        element.action = static_cast<std::uint32_t>(output_.bindings.size());
        output_.bindings.push_back(resolved->action);
        output_.actions.add(std::move(*resolved));
      }
    }
  }

  inline void typography(const Value &value, Element &element) {
    if (const auto size = value.field("size"); size.present()) {
      if (size.is(LUA_TSTRING)) {
        element.size_role = choice(size, {"title", "body", "small"}, 1);
      } else {
        element.size = static_cast<float>(size.boundedNumber(0, 1, 256));
      }
    }

    element.bold = value.field("bold").boolean(false);
    element.italic = value.field("italic").boolean(false);
    element.color = color(value.field("color"));
    element.tone = components::ValueReader::tone(value.field("tone"));
  }

  inline void padding(const Value &value, Element &element) {
    if (!value.present()) {
      return;
    }

    if (!value.is(LUA_TTABLE)) {
      element.padding.fill(length(value, 0));

      return;
    }

    // CSS order: {all}, {vertical, horizontal} or {top, right, bottom, left}.
    const auto count = value.listLength();
    std::array<float, 4> sides{};
    for (std::size_t index = 0; index < std::min<std::size_t>(count, 4); ++index) {
      sides[index] = length(value.element(static_cast<lua_Integer>(index) + 1), 0);
    }

    if (count == 1) {
      element.padding.fill(sides[0]);
    } else if (count == 2) {
      element.padding = {sides[1], sides[0], sides[1], sides[0]};
    } else if (count == 4) {
      element.padding = {sides[3], sides[0], sides[1], sides[2]};
    } else {
      value.fail("must hold one, two or four lengths");
    }
  }

  inline void canvas(const Value &ops, Element &element) {
    struct Shape {
      std::string_view name;
      std::uint8_t numbers;
      bool text;
      bool color;
    };
    // Matches ElementCanvas::Operation, in order.
    constexpr std::array<Shape, 21> shapes{{
        {"move", 2, false, false}, {"line", 2, false, false}, {"curve", 6, false, false}, {"quad", 4, false, false},
        {"arc", 5, false, false}, {"rect", 4, false, false}, {"round_rect", 5, false, false}, {"circle", 3, false, false},
        {"path", 0, true, false}, {"close", 0, false, false}, {"fill", 0, false, true}, {"stroke", 1, false, true},
        {"width", 1, false, false}, {"cap", 0, true, false}, {"join", 0, true, false}, {"alpha", 1, false, false},
        {"translate", 2, false, false}, {"rotate", 1, false, false}, {"scale", 2, false, false}, {"save", 0, false, false},
        {"restore", 0, false, false},
    }};
    element.steps_offset = static_cast<std::uint32_t>(output_.steps.size());
    const auto count = ops.present() ? ops.listLength() : 0;
    for (std::size_t index = 0; index < count; ++index) {
      if (output_.steps.size() == Element::maximum_steps) {
        ops.fail("exceeds 4096 canvas operations");
      }

      const auto op = ops.element(static_cast<lua_Integer>(index) + 1);
      const auto name = op.element(1).string();
      const auto *const shape = std::ranges::find(shapes, name, &Shape::name);
      if (shape == shapes.end()) {
        op.fail("names an unknown canvas operation");
      }

      components::CanvasStep step;
      step.op = static_cast<std::uint8_t>(shape - shapes.begin());
      lua_Integer next = 2;
      if (shape->text) {
        step.text = text(op.element(next++));
      }

      if (shape->color) {
        step.color = color(op.element(next++));
      }

      const auto available = op.listLength() - static_cast<std::size_t>(next - 1);
      step.count = static_cast<std::uint8_t>(std::min<std::size_t>(available, shape->numbers));
      if ((step.count < shape->numbers && shape->name != "stroke" && shape->name != "scale") || available > shape->numbers) {
        op.fail("has the wrong number of values");
      }

      for (std::uint8_t number = 0; number < step.count; ++number) {
        step.values[number] = static_cast<float>(op.element(next++).boundedNumber(0, -1e6, 1e6));
      }

      output_.steps.push_back(step);
    }

    element.steps_count = static_cast<std::uint32_t>(output_.steps.size()) - element.steps_offset;
  }

  inline components::ElementColor color(const Value &value) const {
    components::ElementColor result;
    if (!value.present()) {
      return result;
    }

    if (const auto index = value.asInteger()) {
      if (*index < 0 || *index > std::numeric_limits<std::uint8_t>::max()) {
        value.fail("is outside the color index range");
      }

      result.value = CellColor{.kind = CellColor::Kind::indexed, .channels = {static_cast<std::uint8_t>(*index), 0, 0}};

      return result;
    }

    auto name = value.string();
    constexpr std::size_t rgba_length = std::string_view{"#RRGGBBAA"}.size();
    if (name.size() == rgba_length && name.front() == '#') {
      unsigned alpha = 0;
      const auto parsed = std::from_chars(name.data() + rgba_length - 2, name.data() + rgba_length, alpha, 16);
      if (parsed.ec != std::errc{} || parsed.ptr != name.data() + rgba_length) {
        value.fail("is not a supported color");
      }

      result.alpha = static_cast<std::uint8_t>(alpha);
      name.remove_suffix(2);
    }

    result.value = ColorName::parse(name);
    if (!result.value) {
      value.fail("is not a supported color");
    }

    return result;
  }

  inline static float length(const Value &value, float fallback) {
    return static_cast<float>(value.boundedNumber(fallback, 0, 100000));
  }

  inline static float offset(const Value &value) {
    return static_cast<float>(value.boundedNumber(0, -100000, 100000));
  }

  inline static std::uint8_t choice(const Value &value, std::initializer_list<std::string_view> names, std::uint8_t fallback) {
    if (!value.present()) {
      return fallback;
    }

    const auto name = value.string();
    const auto *const found = std::ranges::find(names, name);
    if (found == names.end()) {
      value.fail("names an unknown option");
    }

    return static_cast<std::uint8_t>(found - names.begin());
  }

  struct Fields {
    std::array<std::string_view, 40> names{};
    std::size_t count = 0;

    // NOLINTNEXTLINE(google-explicit-constructor): reads like the field lists it joins.
    operator std::span<const std::string_view>() const noexcept {
      return std::span{names}.first(count);
    }
  };

  // The fields name what the base and the extra names view, region `a`.
  inline static tbc::view<Fields, tbc::lt::a> combined(tbc::view<std::span<const std::string_view>, tbc::lt::a> base, tbc::view<std::initializer_list<std::string_view>, tbc::lt::a> extra) {
    Fields result;
    for (const auto name : base) {
      result.names[result.count++] = name;
    }

    for (const auto name : extra) {
      result.names[result.count++] = name;
    }

    return result;
  }

  inline components::ElementText text(const Value &value) {
    if (!value.present()) {
      return {};
    }

    return store(value.string(), value);
  }

  inline components::ElementText store(std::string_view text, const Value &value) {
    validateUtf8(text);
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_control = 0x7f;
    if (std::ranges::any_of(text, [](unsigned char byte) {
          return (byte < first_printable && byte != '\n') || byte == delete_control;
        })) {
      value.fail("holds control characters");
    }

    if (text.size() > Element::maximum_text_bytes - output_.text.size()) {
      value.fail("exceeds 256 KiB of element text");
    }

    const components::ElementText range{.offset = static_cast<std::uint32_t>(output_.text.size()), .length = static_cast<std::uint32_t>(text.size())};
    output_.text.append(text);

    return range;
  }

  RenderedElements<Memory> &output_;
  const Action &action_;
  const Callback &callback_;
};

struct ConfigurationSourceText {
  std::string_view source;
  std::string_view directory;
  std::string_view profile;
  std::uint64_t generation = 1;
  const PluginOverrides *plugin_overrides = nullptr;
};

template <Allocator Memory>
class ConfigurationGeneration {
public:
  inline explicit ConfigurationGeneration(Memory &memory, ConfigurationSourceText source)
      : memory_(memory),
        machine_(memory),
        runtime_(makeOwned<runtime::config::RuntimeValues<Memory>>(memory, memory)),
        components_(makeOwned<components::Configuration>(memory, *machine_.state())),
        descriptions_(memory),
        number_(source.generation) {
    profile_.assign(source.profile);
    machine_.execute(config_bootstrap, "@telar/bootstrap.lua", 0);
    lua_getglobal(machine_.state(), "telar");
    runtime::lua::JsonDecoder<Memory>::install(machine_.state(), memory);
    lua_pop(machine_.state(), 1);
    modules_.emplace(machine_.state(), source.directory);
    machine_.execute(source.source, "@config.lua");
    readConfiguration(memory, source.plugin_overrides);
    lua_settop(machine_.state(), 0);
  }

  [[nodiscard]] inline const Configuration &configuration() const noexcept {
    return configuration_;
  }

  [[nodiscard]] inline std::uint64_t number() const noexcept {
    return number_;
  }

  [[nodiscard]] inline const components::Configuration &components() const noexcept {
    return *components_;
  }

  inline void renderBar(components::Position position, const components::Context &context) {
    const auto &source = components_->definitions().source(position);
    renderComponents(source, context, [&](const auto &value, const auto &actions) {
      components_->readBar(position, value, actions, notices_);
    });
  }

  inline void renderPanel(std::size_t index, const components::Context &context) {
    const auto panels = components_->definitions().panels();
    if (index >= panels.size()) {
      throw std::invalid_argument{"Panel is no longer configured"};
    }

    renderComponents(panels[index].source, context, [&](const auto &value, const auto &actions) {
      components_->readPanel(value, actions, notices_);
    });
  }

  inline void closePanel() noexcept {
    components_->closePanel();
  }

  // The members below until configuredAction run on the Lua thread: they read or run the VM.
  [[nodiscard]] inline Owned<RenderedContent<components::BarContent::capacity, Memory>, Memory> renderedBar(components::Position position, const components::Context &context) {
    renderBar(position, context);

    return copied(components_->bar(position));
  }

  [[nodiscard]] inline Owned<RenderedContent<components::PanelContent::capacity, Memory>, Memory> renderedPanel(std::size_t index, const components::Context &context) {
    renderPanel(index, context);

    return copied(components_->panel());
  }

  template <components::Capacity Bounds>
  [[nodiscard]] inline Owned<RenderedContent<Bounds, Memory>, Memory> copied(const components::Content<Bounds> &content) const {
    auto result = makeOwned<RenderedContent<Bounds, Memory>>(memory_, memory_);
    result->content = content;
    for (const auto &node : content.nodes()) {
      if (const auto action = content.action(node)) {
        result->actions.add(resolve(*action));
      }
    }

    return result;
  }

  [[nodiscard]] inline ResolvedAction resolve(BindingAction action) const {
    ResolvedAction result{.action = action};
    if (action.kind == BindingActionKind::extended) {
      result.description = extendedAction(action);
    } else if (action.kind == BindingActionKind::command_tab) {
      if (const auto command = commandTab(action)) {
        result.command.emplace(*command);
      }
    }

    return result;
  }

  [[nodiscard]] inline Owned<ResolvedEffects<Memory>, Memory> invokeResolved(BindingAction action, BindingContext context) {
    auto result = makeOwned<ResolvedEffects<Memory>>(memory_, memory_);
    result->effects = invoke(action, context);
    for (const auto effect : std::span{result->effects.actions}.first(result->effects.length)) {
      if (effect.kind == BindingActionKind::extended || effect.kind == BindingActionKind::command_tab) {
        result->actions.add(resolve(effect));
      }
    }

    return result;
  }

  // Calls a slot's function with the context and the item, a JSON document, and reads the
  // element tree it returns. The instance keeps the `on_click` functions of its last render.
  [[nodiscard]] inline Owned<RenderedElements<Memory>, Memory> renderElements(components::Slot slot, std::uint64_t instance, const components::Context &context, std::string_view item) {
    const auto reference = components_->definitions().slot(slot);
    if (reference == LUA_NOREF) {
      throw std::invalid_argument{"Slot has no render function"};
    }

    auto result = makeOwned<RenderedElements<Memory>>(memory_, memory_);
    Vector<int, Memory> handlers{AllocatorRef<int, Memory>{memory_}};
    const auto release = [&] {
      for (const auto handler : handlers) {
        luaL_unref(machine_.state(), LUA_REGISTRYINDEX, handler);
      }
    };
    client_state_.commands.beginRender();
    try {
      lua_settop(machine_.state(), 0);
      machine_.resetBudget(lua_call_instructions, lua_call_deadline);
      components::Invocation invocation{reference, context, nullptr, item};
      machine_.invoke(&components::Invocation::invoke, &invocation, 1);
      const runtime::lua::Value root{machine_.state(), -1, "element"};
      const auto action = [&](const runtime::lua::Value &value) {
        return elementAction(value, static_cast<std::uint32_t>(result->bindings.size()));
      };
      const auto callback = [&](const runtime::lua::Value &value) {
        if (handlers.size() == components::Element::maximum_actions) {
          value.fail("exceeds 1024 click functions");
        }

        value.pushCopy();
        handlers.push_back(luaL_ref(machine_.state(), LUA_REGISTRYINDEX));

        return static_cast<std::uint32_t>(handlers.size() - 1);
      };
      ElementReader<Memory, decltype(action), decltype(callback)>{*result, action, callback}.read(root);
    } catch (...) {
      release();
      client_state_.commands.endRender();
      lua_settop(machine_.state(), 0);

      throw;
    }

    client_state_.commands.endRender();
    lua_settop(machine_.state(), 0);
    result->callbacks = static_cast<std::uint32_t>(handlers.size());
    auto &kept = handlersOf(instance);
    std::swap(kept.references, handlers);
    release();

    return result;
  }

  // Runs one `on_click` function of the instance's last render and resolves what it returns.
  [[nodiscard]] inline Owned<ResolvedEffects<Memory>, Memory> invokeElement(std::uint64_t instance, std::uint32_t callback, const components::Context &context, std::string_view item) {
    const auto found = std::ranges::find(element_handlers_, instance, &ElementHandlers::instance);
    if (found == element_handlers_.end() || callback >= found->references.size()) {
      throw std::invalid_argument{"That element changed before its click arrived"};
    }

    lua_settop(machine_.state(), 0);
    machine_.resetBudget(lua_call_instructions, lua_call_deadline);
    for (const auto reference : std::span{transient_references_}.first(transient_count_)) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    transient_count_ = 0;
    components::Invocation invocation{found->references[callback], context, nullptr, item};
    machine_.invoke(&components::Invocation::invoke, &invocation, 1);
    auto result = makeOwned<ResolvedEffects<Memory>>(memory_, memory_);
    const runtime::lua::Value value{machine_.state(), -1, "click result"};
    if (value.present()) {
      result->effects = withActions([&](const auto &reader) {
        return effects(value, reader);
      });
    }

    lua_settop(machine_.state(), 0);
    for (const auto effect : std::span{result->effects.actions}.first(result->effects.length)) {
      if (effect.kind == BindingActionKind::extended || effect.kind == BindingActionKind::command_tab) {
        result->actions.add(resolve(effect));
      }
    }

    return result;
  }

  inline void forgetElements(std::uint64_t instance) noexcept {
    const auto found = std::ranges::find(element_handlers_, instance, &ElementHandlers::instance);
    if (found == element_handlers_.end()) {
      return;
    }

    for (const auto reference : found->references) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    element_handlers_.erase(found);
  }

  // Safe on the window thread: configured bindings are fixed when the generation loads.
  [[nodiscard]] inline std::optional<ExtendedActionDescription> configuredAction(BindingAction action) const {
    if (action.kind != BindingActionKind::extended || action.generation != number_) {
      return std::nullopt;
    }

    const auto configured = std::span{input_.configured}.first(input_.length);
    if (std::ranges::find(configured, action, &KeyBinding<BindingAction>::action) == configured.end()) {
      return std::nullopt;
    }

    return descriptions_.at(action.parameter);
  }

  inline void renderPick(std::size_t index, const components::Context &context, components::PickItems &items) {
    const auto picks = components_->definitions().picks();
    if (index >= picks.size()) {
      throw std::invalid_argument{"Pick is no longer configured"};
    }

    const auto &pick = picks[index];
    if (pick.command && !pick.render) {
      components::PickItemsReader::lines(context.output.value_or(std::string_view{}), items, notices_);

      return;
    }

    lua_settop(machine_.state(), 0);
    try {
      if (pick.render) {
        constexpr std::uint64_t pick_instructions = lua_call_instructions;
        constexpr auto pick_deadline = lua_call_deadline;
        machine_.resetBudget(pick_instructions, pick_deadline);
        components::Invocation invocation{pick.reference, context, "items"};
        machine_.invoke(&components::Invocation::invoke, &invocation, 1);
        const runtime::lua::Value result{machine_.state(), -1, "pick items"};
        components::PickItemsReader::read(result, items, notices_);
      } else {
        const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "pick registry"};
        components::PickItemsReader::read(registry.element(pick.reference).field("items"), items, notices_);
      }
    } catch (...) {
      lua_settop(machine_.state(), 0);

      throw;
    }

    lua_settop(machine_.state(), 0);
  }

  template <typename Visitor>
  inline void visitArguments(int reference, const char *field, const Visitor &visit) const {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "source registry"};
    const auto source = registry.element(reference);
    const auto command = source.field(field);
    const auto count = command.listLength();
    for (std::size_t index = 0; index < count; ++index) {
      visit(command.element(static_cast<lua_Integer>(index) + 1).string());
    }
  }

  [[nodiscard]] inline const runtime::config::RuntimeValues<Memory> &runtimeValues() const noexcept {
    return *runtime_;
  }

  [[nodiscard]] inline const ActionDescriptions<Memory> &actionDescriptions() const noexcept {
    return descriptions_;
  }

  [[nodiscard]] inline const runtime::config::RetainedCommandTabRegistry &commandTabs() const noexcept {
    return client_state_.commands;
  }

  [[nodiscard]] inline std::optional<runtime::config::CommandTabView> commandTab(BindingAction action) const {
    if (action.generation != number_ || action.kind != BindingActionKind::command_tab) {
      throw std::invalid_argument{"Command belongs to an obsolete configuration or a different binding kind"};
    }

    const auto reference = commandTabReference(action);

    return reference ? client_state_.commands.load(*reference) : std::nullopt;
  }

  [[nodiscard]] inline std::optional<NotificationActionDescription> notificationAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto *notification = description ? std::get_if<NotificationActionDescription>(&*description) : nullptr;

    return notification == nullptr ? std::nullopt : std::optional{*notification};
  }

  [[nodiscard]] inline const InputConfiguration &input() const noexcept {
    return input_;
  }

  [[nodiscard]] inline std::optional<PluginActionDescription> pluginAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto *plugin = description ? std::get_if<PluginActionDescription>(&*description) : nullptr;

    return plugin == nullptr ? std::nullopt : std::optional{*plugin};
  }

  [[nodiscard]] inline std::optional<DefinitionActionDescription> definitionAction(BindingAction action) const {
    const auto description = extendedAction(action);
    const auto *definition = description ? std::get_if<DefinitionActionDescription>(&*description) : nullptr;

    return definition == nullptr ? std::nullopt : std::optional{*definition};
  }

  [[nodiscard]] inline std::optional<NamedActionDescription> namedAction(BindingAction action) const {
    const auto description = extendedAction(action);
    if (!description) {
      return std::nullopt;
    }

    if (const auto *definition = std::get_if<DefinitionActionDescription>(&*description)) {
      return *definition;
    }

    if (const auto *plugin = std::get_if<PluginActionDescription>(&*description)) {
      return *plugin;
    }

    return std::nullopt;
  }

  template <typename Visitor>
  inline void visitPluginActions(const Visitor &visitor) const {
    const auto visit = [&](BindingAction action) {
      if (const auto plugin = pluginAction(action)) {
        visitor(*plugin);
      }
    };
    for (const auto &binding : std::span{input_.configured}.first(input_.length)) {
      visit(binding.action);
    }

    components_->visitActions(visit);
  }

  [[nodiscard]] inline const BindingMap<BindingAction> &keymap() const noexcept {
    return keymap_;
  }

  template <typename Visitor>
  inline void visitLocalModules(Visitor &&visit) const {
    if (modules_) {
      modules_->visitLoadedNames(machine_.state(), std::forward<Visitor>(visit));
    }
  }

  [[nodiscard]] inline std::size_t localModuleCount() const noexcept {
    return modules_ ? modules_->configurationModuleCount() : 0;
  }

  inline BindingEffects invoke(BindingAction action, BindingContext context) {
    static_cast<void>(callbackBinding(action, BindingActionKind::callback));
    invokeFunction(action.reference, context);
    const runtime::lua::Value result{machine_.state(), -1, "callback result"};

    return withActions([&](const auto &reader) {
      return effects(result, reader);
    });
  }

  inline InputExpression expression(BindingAction action, BindingContext context) {
    const auto &binding = callbackBinding(action, BindingActionKind::expression);
    invokeFunction(action.reference, context);
    const runtime::lua::Value result{machine_.state(), -1, "expression result"};
    const auto kind_value = result.field("input_kind");
    const auto kind = kind_value.string();
    InputExpression decision;
    if (kind == "consume" || kind == "forward") {
      result.onlyFields({"input_kind"});
      decision.kind = kind == "consume" ? InputExpression::Kind::consume : InputExpression::Kind::forward;
      if (kind == "forward") {
        std::ranges::copy(binding.sequence(), decision.keys.begin());
        decision.length = binding.length;
      }
    } else if (kind == "keys") {
      result.onlyFields({"input_kind", "keys"});
      decision.kind = InputExpression::Kind::keys;
      readKeys(result.field("keys"), decision);
    } else if (kind == "paste") {
      result.onlyFields({"input_kind", "text"});
      decision.kind = InputExpression::Kind::paste;
      decision.paste.assign(result.field("text").string());
    } else {
      kind_value.fail("names an unknown input decision");
    }

    return decision;
  }

private:
  static constexpr std::size_t maximum_profile_bytes = 64;
  // Calls run on the Lua thread, so the bound only keeps a runaway loop from holding the queue.
  static constexpr std::uint64_t lua_call_instructions = 50'000'000;
  static constexpr std::chrono::seconds lua_call_deadline{1};

  template <typename Consumer>
  inline void renderComponents(const components::Source &source, const components::Context &context, const Consumer &consume) {
    if (source.kind != components::SourceKind::dynamic && source.kind != components::SourceKind::command) {
      throw std::invalid_argument{"Source has no render callback or command"};
    }

    client_state_.commands.beginRender();
    const auto checkpoint = client_state_.commands.checkpoint();
    try {
      lua_settop(machine_.state(), 0);
      if (source.has_render) {
        constexpr std::uint64_t render_instructions = lua_call_instructions;
        constexpr auto render_deadline = lua_call_deadline;
        machine_.resetBudget(render_instructions, render_deadline);
        components::Invocation invocation{source.reference, context};
        machine_.invoke(&components::Invocation::invoke, &invocation, 1);
      } else {
        const auto output = context.output.value_or(std::string_view{});
        lua_pushlstring(machine_.state(), output.data(), output.size());
      }

      const runtime::lua::Value result{machine_.state(), -1, "component render result"};
      withActions([&](const auto &actions) {
        consume(result, actions);
      });
    } catch (...) {
      client_state_.commands.restore(checkpoint);
      client_state_.commands.endRender();
      lua_settop(machine_.state(), 0);

      throw;
    }

    client_state_.commands.endRender();
    lua_settop(machine_.state(), 0);
  }

  struct ElementHandlers {
    std::uint64_t instance = 0;
    Vector<int, Memory> references;
  };

  ElementHandlers &handlersOf(std::uint64_t instance) {
    const auto found = std::ranges::find(element_handlers_, instance, &ElementHandlers::instance);
    if (found != element_handlers_.end()) {
      return *found;
    }

    element_handlers_.push_back({.instance = instance, .references = Vector<int, Memory>{AllocatorRef<int, Memory>{memory_}}});

    return element_handlers_.back();
  }

  // Reads an element's `on_click` action table and resolves it at once. Its registry entry is
  // released here, so the action carries a reference private to its element tree.
  std::optional<ResolvedAction> elementAction(const runtime::lua::Value &value, std::uint32_t index) {
    const auto action = withActions([&](const auto &reader) {
      return reader.read(value);
    });
    lua_pop(machine_.state(), 1);
    if (!action) {
      return std::nullopt;
    }

    ResolvedAction resolved;
    resolved.action = *action;
    if (action->kind == BindingActionKind::extended) {
      resolved.description = withDefinitions([&](const auto &definitions) {
        return ActionDescriptionReader::read(value, definitions);
      });
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, action->reference);
      constexpr int first_element_reference = -16;
      resolved.action.reference = first_element_reference - static_cast<int>(index);
    } else if (action->kind == BindingActionKind::command_tab) {
      if (const auto command = commandTab(*action)) {
        resolved.command.emplace(*command);
      }
    } else if (action->kind == BindingActionKind::callback || action->kind == BindingActionKind::expression) {
      value.fail("must be an action; a function is called directly");
    }

    return resolved;
  }

  [[nodiscard]] std::optional<ExtendedActionDescription> extendedAction(BindingAction action) const {
    if (action.kind != BindingActionKind::extended) {
      return std::nullopt;
    }

    if (action.generation != number_) {
      throw std::invalid_argument{"Action belongs to an obsolete configuration"};
    }

    const auto configured = std::span{input_.configured}.first(input_.length);
    if (std::ranges::find(configured, action, &KeyBinding<BindingAction>::action) != configured.end()) {
      return descriptions_.at(action.parameter);
    }

    const auto transient = std::span{transient_references_}.first(transient_count_);
    if (!components_->contains(action) && (action.parameter != 0 || !std::ranges::contains(transient, action.reference))) {
      throw std::invalid_argument{"Action is no longer retained"};
    }

    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "action registry"};
    const auto value = registry.element(action.reference);

    return withDefinitions([&](const auto &definitions) {
      return ActionDescriptionReader::read(value, definitions);
    });
  }

  template <typename Consumer>
  auto withDefinitions(Consumer &&consume) const {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "configuration registry"};
    const auto root = registry.element(root_reference_);
    const auto client = root.field("client");
    if (profile_.view().empty()) {
      const runtime::config::ClientDefinitions definitions{client};

      return std::forward<Consumer>(consume)(definitions);
    }

    const auto profiles = root.field("profiles");
    const auto selected = profiles.entry(profile_.view());
    const auto profile_config = selected.as("config");
    const auto overlay = profile_config.field("client");
    const runtime::config::ClientDefinitions definitions{overlay, &client};

    return std::forward<Consumer>(consume)(definitions);
  }

  void readConfiguration(Memory &memory, const PluginOverrides *overrides) {
    const runtime::lua::Value root{machine_.state(), -1, "config"};
    runtime::config::SnapshotReader{memory, *runtime_}.read(root, profile_.view(), client_state_);
    validateUtf8(runtime_->history_path);
    validateUtf8(runtime_->session_path);
    validateUtf8(runtime_->proxy.authority_directory);
    configuration_ = ConfigurationReader::read(root, profile_.view());
    root.pushCopy();
    root_reference_ = luaL_ref(machine_.state(), LUA_REGISTRYINDEX);
    const auto client = root.field("client");
    readClient(client);
    if (!profile_.view().empty()) {
      const auto profiles = root.field("profiles");
      const auto selected = profiles.entry(profile_.view());
      const auto profile_config = selected.as("config");
    const auto overlay = profile_config.field("client");
      readClient(overlay, &client);
    }

    if (overrides != nullptr) {
      overrides->apply(runtime_->plugins);
      removeDisabledPluginBindings(*overrides);
    }

    rebindDefinitions();
    keymap_ = input_.compile();
    withActions([&](const auto &reader) {
      components_->readFixed(reader, notices_);
    });
    client_state_.commands.seal();
  }

  void removeDisabledPluginBindings(const PluginOverrides &overrides) {
    std::size_t retained = 0;
    for (const auto &binding : std::span{input_.configured}.first(input_.length)) {
      if (binding.action.kind == BindingActionKind::extended) {
        const auto *plugin = std::get_if<PluginActionDescription>(&descriptions_.at(binding.action.parameter));
        if (plugin != nullptr && overrides.disabled(plugin->plugin, runtime_->plugins.configured())) {
          continue;
        }
      }

      input_.configured[retained] = binding;
      ++retained;
    }

    input_.length = retained;
  }

  // A profile can replace named definitions while inheriting its keybindings.
  void rebindDefinitions() {
    const runtime::lua::Value registry{machine_.state(), LUA_REGISTRYINDEX, "binding registry"};
    for (const auto &binding : std::span{input_.configured}.first(input_.length)) {
      const auto action = binding.action;
      if (action.kind != BindingActionKind::extended || !std::holds_alternative<DefinitionActionDescription>(descriptions_.at(action.parameter))) {
        continue;
      }

      const auto value = registry.element(action.reference);
      const auto description = withDefinitions([&](const auto &definitions) {
        return ActionDescriptionReader::read(value, definitions);
      });
      descriptions_.replaceDefinition(action.parameter, std::get<DefinitionActionDescription>(description));
    }
  }

  void readClient(const runtime::lua::Value &client, const runtime::lua::Value *inherited = nullptr) {
    components_->definitions().apply(*machine_.state(), client);
    const runtime::config::ClientDefinitions definitions{client, inherited};
    const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
    const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};
    if (client.present() && client.field("keybindings").present()) {
      descriptions_.replaceBindings();
    }

    const RecordingActionReader actions{reader, descriptions_, definitions};
    BindingReader::apply(client, input_, actions);
  }

  template <typename Consumer>
  auto withActions(Consumer &&consume) {
    lua_rawgeti(machine_.state(), LUA_REGISTRYINDEX, root_reference_);
    const runtime::lua::Value root{machine_.state(), -1, "config"};
    const auto client = root.field("client");
    if (profile_.view().empty()) {
      const runtime::config::ClientDefinitions definitions{client};
      const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
      const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

      return std::forward<Consumer>(consume)(reader);
    }

    const auto profiles = root.field("profiles");
    const auto selected = profiles.entry(profile_.view());
    const auto profile_config = selected.as("config");
    const auto overlay = profile_config.field("client");
    const runtime::config::ClientDefinitions definitions{overlay, &client};
    const runtime::config::RetainedActionValidator validator{definitions, notices_, client_state_.commands};
    const BindingActionReader reader{*machine_.state(), validator, client_state_.commands, number_};

    return std::forward<Consumer>(consume)(reader);
  }

  [[nodiscard]] const KeyBinding<BindingAction> &callbackBinding(BindingAction action, BindingActionKind kind) const {
    if (action.generation != number_ || action.kind != kind) {
      throw std::invalid_argument{"Callback belongs to an obsolete configuration or a different binding kind"};
    }

    const auto active = std::span{input_.configured}.first(input_.length);
    const auto found = std::ranges::find(active, action, &KeyBinding<BindingAction>::action);
    if (found == active.end()) {
      throw std::invalid_argument{"Callback is no longer bound"};
    }

    return *found;
  }

  void invokeFunction(int reference, BindingContext context) {
    constexpr std::uint64_t callback_instructions = lua_call_instructions;
    constexpr auto callback_deadline = lua_call_deadline;
    for (const auto reference : std::span{transient_references_}.first(transient_count_)) {
      luaL_unref(machine_.state(), LUA_REGISTRYINDEX, reference);
    }

    transient_count_ = 0;
    lua_settop(machine_.state(), 0);
    machine_.resetBudget(callback_instructions, callback_deadline);
    CallbackInvocation invocation{reference, context};
    machine_.invoke(&CallbackInvocation::invoke, &invocation, 1);
  }

  static void readKeys(const runtime::lua::Value &keys, InputExpression &decision) {
    const auto count = keys.listLength();
    if (count == 0 || count > InputExpression::maximum_keys) {
      keys.fail("must contain one to sixteen keys");
    }

    for (std::size_t index = 0; index < count; ++index) {
      decision.keys[index] = runtime::config::KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
    }

    decision.length = count;
  }

  BindingEffects effects(const runtime::lua::Value &result, const BindingActionReader &reader) {
    if (!result.is(LUA_TTABLE)) {
      result.fail("must be an action or an array of actions");
    }

    BindingEffects batch;
    const auto kind = result.field("kind");
    if (kind.present()) {
      appendEffect(result, reader, batch);

      return batch;
    }

    const auto count = result.listLength();
    batch.dropped = count - std::min(count, BindingEffects::maximum_effects);
    for (std::size_t index = 0; index < std::min(count, BindingEffects::maximum_effects); ++index) {
      appendEffect(result.element(static_cast<lua_Integer>(index) + 1), reader, batch);
    }

    return batch;
  }

  void appendEffect(const runtime::lua::Value &value, const BindingActionReader &reader, BindingEffects &batch) {
    if (value.is(LUA_TFUNCTION)) {
      value.fail("cannot return a recursive callback");
    }

    if (auto action = reader.read(value)) {
      if (action->kind == BindingActionKind::extended) {
        transient_references_[transient_count_++] = action->reference;
      }

      batch.actions[batch.length++] = *action;
    } else {
      ++batch.dropped;
    }
  }

  Memory &memory_;
  runtime::lua::Vm<Memory> machine_;
  Owned<runtime::config::RuntimeValues<Memory>, Memory> runtime_;
  Owned<components::Configuration, Memory> components_;
  std::optional<runtime::config::LocalModules> modules_;
  runtime::config::LimitNotices notices_;
  runtime::config::RetainedClientValidationState client_state_;
  ActionDescriptions<Memory> descriptions_;
  runtime::FixedText<maximum_profile_bytes> profile_;
  Configuration configuration_;
  InputConfiguration input_;
  BindingMap<BindingAction> keymap_;
  std::uint64_t number_;
  int root_reference_ = LUA_NOREF;
  std::array<int, BindingEffects::maximum_effects> transient_references_{};
  std::size_t transient_count_ = 0;
  Vector<ElementHandlers, Memory> element_handlers_{AllocatorRef<ElementHandlers, Memory>{memory_}};
};

}
}
