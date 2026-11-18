#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/text/utf8.hpp"
#include <array>
#include <cstddef>
#include <cstring>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

#include "telar_wire/serializers/telar_cells.hpp"

#include <limits.h>

import telar.testing;
import telar.base.text.utf8;
import telar.gui.features.configuration;
import telar.gui.foundation.core;
import telar.gui.application;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::configuration;

  void completeThemeInheritanceAndProjection() {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    const application::ConfigurationSourceText source{
        .source = R"(
        return {api_version=2,theme={base='vesper',colors={text='#010203',mauve='#040506',panel_bg='default'},
          syntax={keyword={italic=true}},terminal={foreground='#102030',background='#112233'}},
          client={appearance={light={colors={accent='#aabbcc'}}}},
          profiles={selected={theme={base='catppuccin'},client={appearance={
            light={colors={text='#334455'}},dark={colors={surface1='#667788'}}}}}}}
      )",
        .directory = {},
        .profile = "selected",
    };

    const application::ConfigurationGeneration generation{memory, source};
    const auto& themes = generation.configuration().themes;

    check(themes.base.base == ThemeName::catppuccin, "a profile base must replace the complete root theme");
    check(themes.light && themes.light->base == ThemeName::vesper, "appearance overlays must inherit an existing variant independently of the new profile base");
    check(themes.dark && themes.dark->base == ThemeName::catppuccin, "a new appearance variant must inherit the profile's current base");
    const auto light = themes.resolve(Appearance::light);
    const auto keyword = light.syntaxStyle(SyntaxRole::keyword);
    constexpr ThemeRgb inherited_keyword{4, 5, 6};

    check(keyword.italic && !keyword.bold && keyword.color.channels == inherited_keyword, "style-only edits must retain the palette-derived ink and style fields");
    const auto projected = projectTheme(light);
    constexpr auto terminal_foreground = Color::rgb(0x102030);
    constexpr auto chrome_foreground = Color::rgb(0x334455);

    check(projected.foreground == terminal_foreground && projected.chromeColor(PaletteRole::text) == chrome_foreground, "terminal and chrome foreground colors must remain independent");
    check(projected.chromeColor(PaletteRole::panel_bg) == projected.background, "default chrome backgrounds must resolve against the active terminal background");
    const auto dark = projectTheme(themes.resolve(Appearance::dark));
    constexpr auto selected_surface = Color::rgb(0x667788);

    check(dark.elevated == selected_surface && dark.selection == selected_surface, "surface overrides must also reach the selection projection");
    const auto locked = themeValuesByName("terminal");

    check(themes.resolve(Appearance::light, locked) == locked && themes.resolve(Appearance::unknown) == themes.base, "CLI locks must outrank appearance and an unknown appearance must use the base");
  }

  void themeQueriesRetainValuesWithoutAllocation() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;

    {
      const application::ConfigurationSourceText source{
          .source = R"(
          local theme={base='vesper',colors={text='#010203'},syntax={plain='#00007f'}}
          return {api_version=2,theme=theme,client={keybindings={telar.bind({'s'},function()
            theme.colors.text='#aabbcc';return telar.action.new_tab()
          end)}}}
        )",
          .directory = {},
          .profile = {},
      };

      application::ConfigurationGeneration generation{memory, source};
      std::array<char, ConfigurationQuery::capacity> output{};
      const auto allocations = budget.allocations();
      const std::string before{ThemeQuery::write(generation.configuration().themes, output)};

      check(budget.allocations() == allocations, "serializing a retained theme must not allocate through the application allocator");
      check(before.contains(R"("kind":"rgb","value":"\u0001\u0002\u0003")"), "valid RGB UTF-8 storage must serialize as a JSON string");
      check(before.contains(R"("foreground":[255,255,255])"), "invalid RGB UTF-8 storage must serialize as numeric elements");
      static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
      check(ThemeQuery::write(generation.configuration().themes, output) == before, "callbacks must not change the adopted theme snapshot");
      auto all = generation.configuration().themes;

      all.light = themeValuesByName("shade");
      all.dark = themeValuesByName("kanagawa");
      bool rejected = false;

      try {
        static_cast<void>(ThemeQuery::write(all, output));
      } catch (const std::length_error& error) {
        rejected = std::string_view{error.what()} == "WriteFailed";
      }

      check(rejected, "complete appearance themes that exceed the original response buffer must fail without truncation");
      check(ThemeQuery::write(generation.configuration().themes, output) == before, "a rejected oversized query must leave the retained snapshot intact");
    }

    check(budget.liveBytes() == 0, "complete theme snapshots must release all application allocations");
  }

  void syntaxFallbackAndAliases() {
    const auto theme = themeValuesByName("VESPER");
    const auto alias = themeValuesByName("Mocha");

    check(alias.base == ThemeName::catppuccin, "preset aliases must remain case insensitive");
    const auto fallback = theme.syntaxStyle(SyntaxRole::keyword);

    check(fallback.color == theme.color(PaletteRole::mauve) && !fallback.bold, "unconfigured syntax roles must follow the semantic chrome palette");
    const auto shade = themeValuesByName("shade");
    bool shade_italic = false;

    for (std::size_t index = 0; index < syntax_names.size(); ++index) {
      shade_italic = shade_italic || shade.syntaxStyle(static_cast<SyntaxRole>(index)).italic;
    }

    check(!shade_italic, "Shade must not set italic syntax roles");
    const auto plain = shade.syntaxStyle(SyntaxRole::plain).color;
    const auto func = shade.syntaxStyle(SyntaxRole::func).color;
    const auto type = shade.syntaxStyle(SyntaxRole::type).color;

    check(func != plain && type != plain && func != type, "Shade must color functions and types apart from the text and each other");
    check(shade.syntaxStyle(SyntaxRole::parameter).color == plain && shade.syntaxStyle(SyntaxRole::property).color != plain, "Shade must keep parameters in the text color and color properties");
    const auto projected = projectTheme(shade);
    bool syntax_kept = true;

    for (std::size_t index = 0; index < syntax_names.size(); ++index) {
      syntax_kept = syntax_kept && projected.syntax[index] == shade.syntaxStyle(static_cast<SyntaxRole>(index)).color;
    }

    check(syntax_kept, "the projected theme must keep every syntax color for GUI-highlighted text");
    const auto dragon = themeValuesByName("kanagawa_dragon");

    check(dragon.syntaxStyle(SyntaxRole::keyword).italic && dragon.syntaxStyle(SyntaxRole::comment).italic, "generated preset metadata must retain keyword and comment italics");
    const auto zenburn = themeValuesByName("Zenburn");
    bool zenburn_styled = false;

    for (std::size_t index = 0; index < syntax_names.size(); ++index) {
      const auto style = zenburn.syntaxStyle(static_cast<SyntaxRole>(index));

      zenburn_styled = zenburn_styled || style.italic || style.bold;
    }

    check(zenburn.base == ThemeName::zenburn && !zenburn_styled, "Zenburn must not set italic or bold syntax roles");
    const auto zenburn_plain = zenburn.syntaxStyle(SyntaxRole::plain).color;
    const auto zenburn_func = zenburn.syntaxStyle(SyntaxRole::func).color;
    const auto zenburn_type = zenburn.syntaxStyle(SyntaxRole::type).color;

    check(zenburn_func != zenburn_plain && zenburn_type != zenburn_plain && zenburn_func != zenburn_type, "Zenburn must color functions and types apart from the text and each other");
    check(zenburn.terminal.background == ThemeRgb{43, 43, 43}, "Zenburn must paint the terminal zenburn-bg-1");
    check(default_theme_values == zenburn, "Zenburn must be the default theme");
  }

  void utf8InspectionPreservesValidationErrors() {
    constexpr std::array texts{
        std::string_view{"\xff"},
        std::string_view{"\xe2"
                         "AB"},
        std::string_view{"\xe0\x80\x80"},
    };

    constexpr std::array messages{"Invalid UTF-8", "Invalid UTF-8 continuation", "Invalid UTF-8 scalar"};

    for (std::size_t index = 0; index < texts.size(); ++index) {
      bool rejected = false;

      try {
        telar::validateUtf8(texts[index]);
      } catch (const telar::EncodingError& error) {
        rejected = std::string_view{error.what()} == messages[index];
      }

      check(rejected, "nonthrowing UTF-8 inspection must preserve the public validator's precise failure names");
    }
  }

  const telar::testing::Case case_complete_theme_inheritance_and_projection{"theme.complete_theme_inheritance_and_projection", completeThemeInheritanceAndProjection};
  const telar::testing::Case case_theme_queries_retain_values_without_allocation{"theme.theme_queries_retain_values_without_allocation", themeQueriesRetainValuesWithoutAllocation};
  const telar::testing::Case case_syntax_fallback_and_aliases{"theme.syntax_fallback_and_aliases", syntaxFallbackAndAliases};
  const telar::testing::Case case_utf8_inspection_preserves_validation_errors{"theme.utf8_inspection_preserves_validation_errors", utf8InspectionPreservesValidationErrors};

}
