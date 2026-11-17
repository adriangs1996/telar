module;
#include "tbc/annotations.hpp"

export module telar.gui.config.generation;

import std;

import telar.gui.foundation.actions;
import telar.lua;

import telar.gui.foundation.keys;

import telar.gui.foundation.core;

import telar.gui.components.configuration;
import telar.gui.components.builtin_content;
import telar.gui.presentation.suggestion_geometry;
import telar.wire.vocabulary;
import telar.config.gui;
import telar.config.client;

// Interface: config/action_description_reader.cppm
export {
  namespace telar::gui {

    // Maps what runtime::config::ExtendedActionReader read onto the GUI's descriptions.
    class ActionDescriptionReader {
    public:
      static ExtendedActionDescription read(const runtime::lua::Value& value, const runtime::config::ClientDefinitions& definitions);

    private:
      static ExtendedActionDescription description(const runtime::config::NotificationActionSetting& setting);
      static ExtendedActionDescription description(const runtime::config::PluginActionSetting& setting);
      static ExtendedActionDescription description(const runtime::config::DefinitionActionSetting& setting);
    };

  }
}

// Interface: config/action_reader.cppm
export {
  namespace telar::gui {

    class BindingActionReader {
    public:
      explicit BindingActionReader(lua_State& state, const runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation);

      [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value& value, bool expression = false) const;

    private:
      [[nodiscard]] BindingAction command(const runtime::config::CommandTabView& command) const;

      // The configuration admits only the names the GUI binds.
      static BindingAction builtin(const runtime::lua::Value& value, std::string_view name);

      [[nodiscard]] BindingAction referenced(const runtime::lua::Value& value, BindingActionKind kind) const;

      lua_State& state_;
      const runtime::config::RetainedActionValidator& validator_;
      runtime::config::RetainedCommandTabRegistry& commands_;
      std::uint64_t generation_;
    };

  }
}

// Interface: config/binding_reader.cppm
export {
  namespace telar::gui {

    template <typename Reader>
    concept BindingActionSource = requires(const Reader& reader, const runtime::lua::Value& value) {
      { reader.read(value, false) } -> std::same_as<std::optional<BindingAction>>;
    };

    class BindingReader {
      using Reader = runtime::config::ClientReader;

    public:
      static_assert(BindingLimits::bindings == runtime::config::BindingReader::maximum_bindings);
      static_assert(BindingLimits::keys == runtime::config::BindingSetting::maximum_keys);

      template <BindingActionSource Actions>
      TBC_GENERIC static void apply(const runtime::lua::Value& client, InputConfiguration& input, const Actions& actions) {
        const auto settings = Reader::input(client);
        if (settings.prefix) {
          input.setPrefix(*settings.prefix);
        }

        constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;

        if (settings.sequence_timeout_ms) {
          input.sequence_timeout_ns = *settings.sequence_timeout_ms * nanoseconds_per_millisecond;
        }

        if (Reader::listsBindings(client)) {
          input.length = 0;
        }

        const auto listed = Reader::bindings(client, input.prefix, [&](const runtime::config::BindingSetting& setting, const runtime::lua::Value& value) {
          KeyBinding<BindingAction> binding{.prefixed = setting.prefixed};

          std::ranges::copy(std::span{setting.keys}.first(setting.length), binding.keys.begin());
          binding.length = setting.length;
          if (const auto action = actions.read(value, setting.expression)) {
            binding.action = *action;
            input.configured[input.length++] = binding;
          }
        });
        if (listed) {
          input.dropped = *listed - std::min(*listed, BindingLimits::bindings);
        }
      }
    };

  }
}

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
