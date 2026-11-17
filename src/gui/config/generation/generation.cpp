module telar.gui.config.generation;

import telar.gui.config.gui_query;
import telar.gui.foundation.core;
import telar.gui.foundation.actions;
import telar.gui.config.plugin_query;
import telar.plugins;
import telar.config.core;

namespace telar::gui {

  ExtendedActionDescription ActionDescriptionReader::read(const runtime::lua::Value& value, const runtime::config::ClientDefinitions& definitions) {
    return std::visit(
        [](const auto& setting) {
          return description(setting);
        },
        runtime::config::ExtendedActionReader::read(value, definitions)
    );
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::NotificationActionSetting& setting) {
    NotificationActionDescription result;

    result.title.assign(setting.title);
    result.message.assign(setting.body);
    result.level = setting.level;
    result.duration_ms = setting.duration_ms;
    result.target = setting.target;

    return result;
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::PluginActionSetting& setting) {
    return PluginActionDescription{.plugin = runtime::plugins::stableId(setting.plugin), .action = runtime::plugins::stableId(setting.action)};
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::DefinitionActionSetting& setting) {
    return DefinitionActionDescription{.kind = setting.panel ? DefinitionActionDescription::Kind::panel : DefinitionActionDescription::Kind::pick, .index = setting.index};
  }

  BindingActionReader::BindingActionReader(lua_State& state, const runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation)
      : state_(state),
        validator_(validator),
        commands_(commands),
        generation_(generation) {}

  std::optional<BindingAction> BindingActionReader::read(const runtime::lua::Value& value, bool expression) const {
    using Kind = runtime::config::ActionKind;

    const auto setting = validator_.read(value, expression);
    if (!setting) {
      return {};
    }

    switch (setting->kind) {
    case Kind::function:
      return referenced(value, expression ? BindingActionKind::expression : BindingActionKind::callback);
    case Kind::builtin:
      return builtin(value, setting->name);
    case Kind::select_tab:
    case Kind::select_workspace:
      return BindingAction{.kind = setting->kind == Kind::select_tab ? BindingActionKind::select_tab : BindingActionKind::select_workspace, .parameter = setting->number - 1};
    case Kind::select_tab_offset:
      return BindingAction{.kind = BindingActionKind::select_tab_offset, .parameter = setting->number};
    case Kind::command_tab:
      return command(setting->command);
    case Kind::notification:
    case Kind::panel:
    case Kind::pick:
    case Kind::plugin:
      return referenced(value, BindingActionKind::extended);
    }

    return {};
  }

  BindingAction BindingActionReader::command(const runtime::config::CommandTabView& command) const {
    runtime::config::LimitNotices limits;
    const auto reference = commands_.keepReference(command.argv(), command.configured_label, limits);
    if (!reference) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return commandTabAction(*reference, generation_);
  }

  BindingAction BindingActionReader::builtin(const runtime::lua::Value& value, std::string_view name) {
    if (const auto action = builtinBindingAction(name)) {
      return *action;
    }

    value.fail("names an unknown binding action");
  }

  BindingAction BindingActionReader::referenced(const runtime::lua::Value& value, BindingActionKind kind) const {
    value.pushCopy();

    return {.kind = kind, .reference = luaL_ref(&state_, LUA_REGISTRYINDEX), .generation = generation_};
  }

  std::string_view canonicalThemeName(std::string_view name) noexcept {
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

  ThemeValues themeValuesByName(std::string_view name) {
    constexpr std::size_t maximum_name_bytes = 64;
    if (name.size() > maximum_name_bytes) {
      throw std::invalid_argument{"GUI theme name exceeds capacity"};
    }

    std::array<char, maximum_name_bytes> lowercase{};

    std::ranges::transform(name, lowercase.begin(), [](char character) {
      return character >= 'A' && character <= 'Z' ? static_cast<char>(character + 'a' - 'A') : character;
    });

    const auto canonical = canonicalThemeName({lowercase.data(), name.size()});
    const auto* const found = std::ranges::find_if(theme_presets, [&](const auto& preset) {
      return preset.name == canonical;
    });
    if (found == theme_presets.end()) {
      throw std::invalid_argument{"Unknown GUI theme"};
    }

    return found->values;
  }

  Theme themeByName(std::string_view name) {
    return projectTheme(themeValuesByName(name));
  }

  void ThemeReader::apply(const runtime::config::ThemeSelectionSettings& settings, ThemeSelection& selection) {
    applyTheme(settings.base, selection.base);
    applyVariant(settings.light, selection.light, selection.base);
    applyVariant(settings.dark, selection.dark, selection.base);
  }

  CellColor ThemeReader::color(const runtime::config::ThemeColor& color) noexcept {
    if (!color.rgb) {
      return {};
    }

    return {.kind = CellColor::Kind::rgb, .channels = *color.rgb};
  }

  void ThemeReader::applyVariant(const std::optional<Settings>& settings, std::optional<ThemeValues>& variant, const ThemeValues& base) {
    if (!settings) {
      return;
    }

    auto result = variant.value_or(base);

    applyTheme(settings, result);
    variant = result;
  }

  void ThemeReader::applyTheme(const std::optional<Settings>& settings, ThemeValues& theme) {
    if (!settings) {
      return;
    }

    if (settings->preset) {
      theme = themeValuesByName(*settings->preset);
    }

    for (std::size_t index = 0; index < settings->colors.size(); ++index) {
      if (settings->colors[index]) {
        theme.palette[index] = color(*settings->colors[index]);
      }
    }

    applyTerminal(settings->terminal, theme.terminal);
    applySyntax(*settings, theme);
  }

  void ThemeReader::applyTerminal(const Settings::Terminal& settings, TerminalThemeValues& terminal) noexcept {
    terminal.foreground = settings.foreground.value_or(terminal.foreground);
    terminal.background = settings.background.value_or(terminal.background);
    if (settings.cursor_color) {
      terminal.cursor_color = settings.cursor_color;
    }

    if (settings.cursor_text_color) {
      terminal.cursor_text_color = settings.cursor_text_color;
    }

    terminal.palette = settings.palette.value_or(terminal.palette);
  }

  void ThemeReader::applySyntax(const Settings& settings, ThemeValues& theme) {
    for (std::size_t index = 0; index < settings.syntax.size(); ++index) {
      const auto& entry = settings.syntax[index];
      if (!entry) {
        continue;
      }

      auto style = theme.syntaxStyle(static_cast<SyntaxRole>(index));

      if (entry->color) {
        style.color = color(*entry->color);
      }

      style.italic = entry->italic.value_or(style.italic);
      style.bold = entry->bold.value_or(style.bold);
      theme.syntax_styles[index] = style;
    }
  }

}
