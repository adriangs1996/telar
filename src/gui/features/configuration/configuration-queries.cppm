// What a client reads of a loaded configuration: the sections it asks for, each written as JSON,
// and the actions and bindings in them, with the command tabs a binding names.
export module telar.gui.features.configuration:queries;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.config.client;
import telar.config.gui;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;

// Interface: config/query.cppm
export {
  namespace telar::gui::features::configuration {

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

// Interface: config/gui_query.cppm
export {
  namespace telar::gui::features::configuration {

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

// Interface: config/theme_query.cppm
export {
  namespace telar::gui::features::configuration {

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

// Interface: config/command_tab_action.cppm
export {
  namespace telar::gui::features::configuration {

    [[nodiscard]] BindingAction commandTabAction(runtime::config::CommandTabReference reference, std::uint64_t generation) noexcept;

    [[nodiscard]] std::optional<runtime::config::CommandTabReference> commandTabReference(BindingAction action) noexcept;

  }
}

// Interface: config/action_query.cppm
export {
  namespace telar::gui::features::configuration {

    class ActionQuery {
    public:
      template <Allocator Memory>
      static void write(JsonWriter& writer, BindingAction action, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

    private:
      template <typename Value>
      static void writeValue(JsonWriter& writer, std::string_view type, const Value& value);

      struct NamedAction {
        BindingActionKind kind;
        std::string_view type;
        std::string_view value;
      };

      static bool writeNamed(JsonWriter& writer, BindingActionKind kind);
      static void writeNumeric(JsonWriter& writer, BindingAction action);
      static void writeStoredCommand(JsonWriter& writer, runtime::config::CommandTabReference reference, const runtime::config::RetainedCommandTabRegistry& commands);
      static void writeCommand(JsonWriter& writer, const runtime::config::CommandTabView& command);
      static void writeArguments(JsonWriter& writer, std::span<const std::string_view> arguments);
      static void writeExtended(JsonWriter& writer, const NotificationActionDescription& description);
      static void writeNotification(JsonWriter& writer, const NotificationActionDescription& description);
      static void emptyObject(JsonWriter& writer);
      static void writeTarget(JsonWriter& writer, NotificationTarget target);
      static void writeExtended(JsonWriter& writer, DefinitionActionDescription description);
      static void writeExtended(JsonWriter& writer, PluginActionDescription description);
    };

    extern template void ActionQuery::write<telar::Memory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);
    extern template void ActionQuery::write<telar::ConcurrentMemory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

  }
}

// Interface: config/input_query.cppm
export {
  namespace telar::gui::features::configuration {

    class InputQuery {
    public:
      // Each query is written into the output, region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const InputConfiguration& input, tbc::view<std::span<char>, tbc::lt::a> output);

      static void writeKey(JsonWriter& writer, KeyChord key);

    private:
      static void writeCode(JsonWriter& writer, KeyChord key);
      static void writeEmptyObject(JsonWriter& writer);
      static void writeCharacter(JsonWriter& writer, KeyChord key);
      static std::string_view keyName(KeyChord::Key key);
    };

  }
}

// Interface: config/binding_query.cppm
export {
  namespace telar::gui::features::configuration {

    class BindingQuery {
    public:
      template <Allocator Memory>
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> write(const InputConfiguration& input, std::size_t index, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      static void writeKeys(JsonWriter& writer, std::span<const KeyChord> keys);
    };

    extern template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::Memory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);
    extern template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::ConcurrentMemory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

  }
}
