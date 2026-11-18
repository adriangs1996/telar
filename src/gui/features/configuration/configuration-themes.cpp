module telar.gui.features.configuration;

import std;

import telar.config.client;
import telar.config.gui;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.text;
import telar.base.ds;

namespace telar::gui::features::configuration {

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

  void ThemeReader::applyVariant(const ds::Option<Settings>& settings, ds::Option<ThemeValues>& variant, const ThemeValues& base) {
    if (!settings) {
      return;
    }

    auto result = variant.valueOr(base);

    applyTheme(settings, result);
    variant = result;
  }

  void ThemeReader::applyTheme(const ds::Option<Settings>& settings, ThemeValues& theme) {
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
    terminal.foreground = settings.foreground.valueOr(terminal.foreground);
    terminal.background = settings.background.valueOr(terminal.background);
    if (settings.cursor_color) {
      terminal.cursor_color = settings.cursor_color;
    }

    if (settings.cursor_text_color) {
      terminal.cursor_text_color = settings.cursor_text_color;
    }

    terminal.palette = settings.palette.valueOr(terminal.palette);
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

      style.italic = entry->italic.valueOr(style.italic);
      style.bold = entry->bold.valueOr(style.bold);
      theme.syntax_styles[index] = style;
    }
  }

}
