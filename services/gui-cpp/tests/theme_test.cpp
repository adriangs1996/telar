#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>
#include "telar_base/text/utf8.hpp"
#include <string_view>
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
#include <optional>
#include <string>
#include <limits>
#include <utility>
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
#include "telar_client/codecs/telar_wire.hpp"
#include <functional>
#include <type_traits>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.config.generation;
import telar.gui.config.gui_query;
import telar.gui.core.metrics;
import telar.gui.input.copy_pointer;
import telar.gui.presentation.suggestion_geometry;



namespace {

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void completeThemeInheritanceAndProjection() {
  SystemAllocator memory;
  const ConfigurationSourceText source{
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
  const ConfigurationGeneration generation{memory, source};
  const auto &themes = generation.configuration().themes;
  require(themes.base.base == ThemeName::catppuccin, "a profile base must replace the complete root theme");
  require(themes.light && themes.light->base == ThemeName::vesper, "appearance overlays must inherit an existing variant independently of the new profile base");
  require(themes.dark && themes.dark->base == ThemeName::catppuccin, "a new appearance variant must inherit the profile's current base");
  const auto light = themes.resolve(Appearance::light);
  const auto keyword = light.syntaxStyle(SyntaxRole::keyword);
  constexpr ThemeRgb inherited_keyword{4, 5, 6};
  require(keyword.italic && !keyword.bold && keyword.color.channels == inherited_keyword, "style-only edits must retain the palette-derived ink and style fields");
  const auto projected = projectTheme(light);
  constexpr auto terminal_foreground = Color::rgb(0x102030);
  constexpr auto chrome_foreground = Color::rgb(0x334455);
  require(projected.foreground == terminal_foreground && projected.chromeColor(PaletteRole::text) == chrome_foreground, "terminal and chrome foreground colors must remain independent");
  require(projected.chromeColor(PaletteRole::panel_bg) == projected.background, "default chrome backgrounds must resolve against the active terminal background");
  const auto dark = projectTheme(themes.resolve(Appearance::dark));
  constexpr auto selected_surface = Color::rgb(0x667788);
  require(dark.elevated == selected_surface && dark.selection == selected_surface, "surface overrides must also reach the selection projection");
  const auto locked = themeValuesByName("terminal");
  require(themes.resolve(Appearance::light, locked) == locked && themes.resolve(Appearance::unknown) == themes.base, "CLI locks must outrank appearance and an unknown appearance must use the base");
}

void themeQueriesRetainValuesWithoutAllocation() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  {
    const ConfigurationSourceText source{
        .source = R"(
          local theme={base='vesper',colors={text='#010203'},syntax={plain='#00007f'}}
          return {api_version=2,theme=theme,client={keybindings={telar.bind({'s'},function()
            theme.colors.text='#aabbcc';return telar.action.new_tab()
          end)}}}
        )",
        .directory = {},
        .profile = {},
    };
    ConfigurationGeneration generation{memory, source};
    std::array<char, ConfigurationQuery::capacity> output{};
    const auto allocations = memory.allocations();
    const std::string before{ThemeQuery::write(generation.configuration().themes, output)};
    require(memory.allocations() == allocations, "serializing a retained theme must not allocate through the application allocator");
    require(before.contains(R"("kind":"rgb","value":"\u0001\u0002\u0003")"), "valid RGB UTF-8 storage must serialize as a JSON string");
    require(before.contains(R"("foreground":[255,255,255])"), "invalid RGB UTF-8 storage must serialize as numeric elements");
    static_cast<void>(generation.invoke(generation.input().configured.front().action, {}));
    require(ThemeQuery::write(generation.configuration().themes, output) == before, "callbacks must not change the adopted theme snapshot");
    auto all = generation.configuration().themes;
    all.light = themeValuesByName("shade");
    all.dark = themeValuesByName("kanagawa");
    bool rejected = false;
    try {
      static_cast<void>(ThemeQuery::write(all, output));
    } catch (const std::length_error &error) {
      rejected = std::string_view{error.what()} == "WriteFailed";
    }

    require(rejected, "complete appearance themes that exceed the original response buffer must fail without truncation");
    require(ThemeQuery::write(generation.configuration().themes, output) == before, "a rejected oversized query must leave the retained snapshot intact");
  }

  require(memory.liveBytes() == 0, "complete theme snapshots must release all application allocations");
}

void syntaxFallbackAndAliases() {
  const auto theme = themeValuesByName("VESPER");
  const auto alias = themeValuesByName("Mocha");
  require(alias.base == ThemeName::catppuccin, "preset aliases must remain case insensitive");
  const auto fallback = theme.syntaxStyle(SyntaxRole::keyword);
  require(fallback.color == theme.color(PaletteRole::mauve) && !fallback.bold, "unconfigured syntax roles must follow the semantic chrome palette");
  const auto shade = themeValuesByName("shade");
  require(shade.syntaxStyle(SyntaxRole::parameter).italic && !shade.syntaxStyle(SyntaxRole::plain).italic, "generated syntax preferences must preserve the original preset's role styles");
  const auto dragon = themeValuesByName("kanagawa_dragon");
  require(dragon.syntaxStyle(SyntaxRole::keyword).italic && dragon.syntaxStyle(SyntaxRole::comment).italic, "generated preset metadata must retain keyword and comment italics");
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
    } catch (const telar::EncodingError &error) {
      rejected = std::string_view{error.what()} == messages[index];
    }

    require(rejected, "nonthrowing UTF-8 inspection must preserve the public validator's precise failure names");
  }
}

}

int main() {
  try {
    completeThemeInheritanceAndProjection();
    themeQueriesRetainValuesWithoutAllocation();
    syntaxFallbackAndAliases();
    utf8InspectionPreservesValidationErrors();
    std::puts("gui-theme: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-theme: " << error.what() << '\n';

    return 1;
  }
}
