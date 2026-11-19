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

#include <climits>

import telar.testing;
import telar.testing.test_memory;
import telar.base.text.utf8;
import telar.gui.features.configuration;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.gui.application.tests.session_fixture;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::configuration;

  void completeThemeInheritanceAndProjection() {
    telar::testing::TestMemory adapter;
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
      telar::ds::Array<char, ConfigurationQuery::capacity> output{};
      const auto allocations = budget.allocations();
      const std::string before{ThemeQuery::write(generation.configuration().themes, output.viewMut())};

      check(budget.allocations() == allocations, "serializing a retained theme must not allocate through the application allocator");
      check(before.contains(R"("kind":"rgb","value":"\u0001\u0002\u0003")"), "valid RGB UTF-8 storage must serialize as a JSON string");
      check(before.contains(R"("foreground":[255,255,255])"), "invalid RGB UTF-8 storage must serialize as numeric elements");
      static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
      check(ThemeQuery::write(generation.configuration().themes, output.viewMut()) == before, "callbacks must not change the adopted theme snapshot");
      auto all = generation.configuration().themes;

      all.light = themeValuesByName("shade");
      all.dark = themeValuesByName("kanagawa");
      bool rejected = false;

      try {
        static_cast<void>(ThemeQuery::write(all, output.viewMut()));
      } catch (const std::length_error& error) {
        rejected = std::string_view{error.what()} == "WriteFailed";
      }

      check(rejected, "complete appearance themes that exceed the original response buffer must fail without truncation");
      check(ThemeQuery::write(generation.configuration().themes, output.viewMut()) == before, "a rejected oversized query must leave the retained snapshot intact");
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
    constexpr ThemeRgb zenburn_bg_1{43, 43, 43};

    check(zenburn.terminal.background == zenburn_bg_1, "Zenburn must paint the terminal zenburn-bg-1");
    check(default_theme_values == zenburn, "Zenburn must be the default theme");
  }

  // Zenburn's numbers and properties have no ANSI color: a pane's programs get them from the
  // editor colors, beside the terminal colors the terminal shows.
  void terminalColorsCarryTheEditorColors() {
    const auto zenburn = themeValuesByName("zenburn");
    const auto colors = application::configuration::terminalColors(projectTheme(zenburn));
    const auto syntax = [&](SyntaxRole role) {
      const auto index = static_cast<std::size_t>(role) * 3;

      return ThemeRgb{(*colors.syntax)[index], (*colors.syntax)[index + 1], (*colors.syntax)[index + 2]};
    };

    check(colors.background && *colors.background == zenburn.terminal.background && colors.foreground && *colors.foreground == zenburn.terminal.foreground, "the terminal colors are the theme's");

    bool palette_kept = colors.palette.hasValue();

    for (std::size_t index = 0; palette_kept && index < zenburn.terminal.palette.size(); ++index) {
      palette_kept = ThemeRgb{(*colors.palette)[index * 3], (*colors.palette)[(index * 3) + 1], (*colors.palette)[(index * 3) + 2]} == zenburn.terminal.palette[index];
    }

    check(palette_kept, "the 16 ANSI colors are the theme's terminal palette");
    constexpr ThemeRgb number_color{191, 235, 191};
    constexpr ThemeRgb property_color{223, 175, 143};

    check(colors.syntax && syntax(SyntaxRole::number) == number_color && syntax(SyntaxRole::property) == property_color, "every syntax role keeps its own color");
    check(colors.chrome && colors.syntax_italic == 0 && colors.syntax_bold == 0, "the chrome colors travel, and Zenburn styles no role");

    const auto dragon = application::configuration::terminalColors(projectTheme(themeValuesByName("kanagawa_dragon")));
    const auto bit = [](SyntaxRole role) {
      return static_cast<std::uint16_t>(1U << static_cast<unsigned>(role));
    };

    check((dragon.syntax_italic & bit(SyntaxRole::keyword)) != 0 && (dragon.syntax_italic & bit(SyntaxRole::comment)) != 0, "italic syntax roles travel as their bits");
  }

  // The runtime hears the theme when the session connects and whenever it changes, never from a
  // session on a runtime that cannot read it.
  void sessionGivesTheRuntimeItsTheme() {
    using namespace application::tests::session_fixture;

    telar::SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    client.connected(1);
    check(transport.count(telar::ClientTag::configure_terminal_colors) == 1, "connecting gives the runtime the theme");

    auto theme = client.configuration.theme;

    application::configuration::setTheme(client, theme);
    check(transport.count(telar::ClientTag::configure_terminal_colors) == 1, "an unchanged theme is not sent again");
    theme.syntax_italic = 1;
    application::configuration::setTheme(client, theme);
    check(transport.count(telar::ClientTag::configure_terminal_colors) == 2 && transport.last<telar::ConfigureTerminalColors>().syntax_italic == 1, "a changed theme reaches the runtime");

    auto configuration = client.configuration;

    configuration.theme.syntax_bold = 1;
    application::configuration::configure(client, configuration);
    check(transport.count(telar::ClientTag::configure_terminal_colors) == 3 && transport.last<telar::ConfigureTerminalColors>().syntax_bold == 1, "a configuration with a new theme reaches the runtime");

    Transport legacy_transport;
    TestSession legacy{memory, legacy_transport};

    legacy.connected(1, true, false);
    theme.syntax_italic = 2;
    application::configuration::setTheme(legacy, theme);
    check(legacy_transport.count(telar::ClientTag::configure_terminal_colors) == 0, "a runtime before themes never hears one");
  }

  void utf8InspectionPreservesValidationErrors() {
    constexpr telar::ds::Array texts{
        std::string_view{"\xff"},
        std::string_view{"\xe2"
                         "AB"},
        std::string_view{"\xe0\x80\x80"},
    };

    constexpr telar::ds::Array messages{"Invalid UTF-8", "Invalid UTF-8 continuation", "Invalid UTF-8 scalar"};

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
  const telar::testing::Case case_terminal_colors_carry_the_editor_colors{"theme.terminal_colors_carry_the_editor_colors", terminalColorsCarryTheEditorColors};
  const telar::testing::Case case_session_gives_the_runtime_its_theme{"theme.session_gives_the_runtime_its_theme", sessionGivesTheRuntimeItsTheme};
  const telar::testing::Case case_utf8_inspection_preserves_validation_errors{"theme.utf8_inspection_preserves_validation_errors", utf8InspectionPreservesValidationErrors};

}
