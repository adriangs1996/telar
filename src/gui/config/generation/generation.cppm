module;
#include "tbc/annotations.hpp"

export module telar.gui.config.generation;

import std;

import telar.gui.foundation.core;

import telar.wire.vocabulary;
import telar.config.gui;
import telar.config.client;

// Interface: config/themes.cppm
export {
  namespace telar::gui {

    std::string_view canonicalThemeName(std::string_view name) noexcept;

    ThemeValues themeValuesByName(std::string_view name);

    Theme themeByName(std::string_view name);

  }
}

// Interface: config/theme_reader.cppm
export {
  namespace telar::gui {

    // Applies the themes runtime::config::ThemeReader read onto the GUI's presets.
    class ThemeReader {
      using Settings = runtime::config::ThemeSettings;

    public:
      static_assert(std::ranges::equal(palette_names, runtime::config::theme_color_names));
      static_assert(std::ranges::equal(syntax_names, runtime::config::theme_syntax_names));
      static_assert(TerminalThemeValues::palette_size == Settings::Terminal::palette_size);

      static void apply(const runtime::config::ThemeSelectionSettings& settings, ThemeSelection& selection);

    private:
      static CellColor color(const runtime::config::ThemeColor& color) noexcept;
      static void applyVariant(const std::optional<Settings>& settings, std::optional<ThemeValues>& variant, const ThemeValues& base);
      static void applyTheme(const std::optional<Settings>& settings, ThemeValues& theme);
      static void applyTerminal(const Settings::Terminal& settings, TerminalThemeValues& terminal) noexcept;
      static void applySyntax(const Settings& settings, ThemeValues& theme);
    };

  }
}
