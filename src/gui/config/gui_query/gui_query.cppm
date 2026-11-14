module;

export module telar.gui.config.gui_query;

import std;
import telar.tbc;

export import telar.gui.presentation.client_view_state;
export import telar.gui.core.metrics;
export import telar.gui.core.json_writer;

import telar.base.diagnostics;
import telar.config.gui;
import telar.gui.input.copy_pointer;
import telar.gui.input.key_encoder;
import telar.wire.vocabulary;

// Interface: config/query.cppm
export {
  namespace telar::gui {

    struct ConfigurationQuery {
      static constexpr std::size_t capacity = 4096;

      enum class Section : std::uint8_t {
        client,
        theme,
        gui,
        input,
        runtime,
        binding,
      };

      Section section = Section::client;
      std::int64_t index = 0;

      static constexpr auto sections = std::to_array<std::pair<std::string_view, Section>>({
          {"client", Section::client},
          {"theme", Section::theme},
          {"gui", Section::gui},
          {"input", Section::input},
          {"runtime", Section::runtime},
          {"binding", Section::binding},
      });

      [[nodiscard]] static ConfigurationQuery parse(std::string_view name, std::int64_t index);
    };

  }
}

// Interface: config/client_query.cppm
export {
  namespace telar::gui {

    struct ClientQueryContext {
      std::optional<std::string_view> source;
      std::optional<std::string_view> profile;
      std::uint64_t generation = 0;
      ClientViewState view;
    };

    class ClientQuery {
    public:
      // Each query is written into the output, region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const Configuration& configuration, const ClientQueryContext& context, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static void writeOptionalBytes(JsonWriter& writer, std::optional<std::string_view> text);
      static void writeSound(JsonWriter& writer, SoundPolicy policy);
      static void writeSections(JsonWriter& writer);
    };

  }
}

// Interface: config/gui_query.cppm
export {
  namespace telar::gui {

    class GuiQuery {
    public:
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const Configuration& configuration, tbc::view<std::span<char>, tbc::lt::a> output, bool default_titlebar);

    private:
      static void writeFont(JsonWriter& writer, const FontConfiguration& font);
      static void writeWindow(JsonWriter& writer, const Configuration& configuration, bool default_titlebar);

      // CursorShape leads with the terminal's default, which a configuration cannot choose.
      static std::string_view cursorStyle(CursorShape cursor);
    };

  }
}

// Interface: config/palette_actions.cppm
export {
#include "config/palette_actions.inc"
}

// Interface: config/theme_presets.cppm
export {
#include "config/theme_presets.inc"
}

// Interface: config/theme_query.cppm
export {
  namespace telar::gui {

    class ThemeQuery {
    public:
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const ThemeSelection& selection, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static void byteValue(JsonWriter& writer, ThemeRgb bytes);
      static void writeColor(JsonWriter& writer, CellColor color);
      static void writeTheme(JsonWriter& writer, const ThemeValues& theme);
      static void writePalette(JsonWriter& writer, const ThemeValues& theme);
      static void writeOptionalRgb(JsonWriter& writer, const std::optional<ThemeRgb>& color);
      static void writeTerminal(JsonWriter& writer, const TerminalThemeValues& terminal);
      static void writeRgbPalette(JsonWriter& writer, std::span<const ThemeRgb> colors);
      static void writeSyntaxStyles(JsonWriter& writer, const ThemeValues& theme);
      static void writeStyles(JsonWriter& writer, const ThemeValues& theme);
      static void writeStyle(JsonWriter& writer, const SyntaxStyleValues& style);
      static void writeOptionalTheme(JsonWriter& writer, const std::optional<ThemeValues>& theme);
    };

  }
}
