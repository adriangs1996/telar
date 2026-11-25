module;
#include "tbc/annotations.hpp"

// What the theme picker lists and keeps: the presets beside the themes a configuration names,
// the command it runs once a theme is chosen, and the choice it saves for every window.
export module telar.gui.features.configuration:theme_picker;

import std;

import telar.base.memory.containers;
import telar.config.gui;
import telar.gui.foundation.core;
import telar.base.ds;
import telar.tbc;
import :themes;

// Interface: config/theme_catalog.cppm
export {
  namespace telar::gui::features::configuration {

    // One theme the picker lists: the name a preset or the configuration gives it, the name it
    // shows, and its colors.
    struct ThemeEntry {
      static constexpr std::size_t name_bytes = runtime::config::ThemeReader::maximum_theme_name_bytes;

      runtime::FixedText<name_bytes> name;
      runtime::FixedText<name_bytes> label;
      // The preset this theme stands for, by its canonical name, or its own name.
      runtime::FixedText<name_bytes> canonical;
      ThemeValues values;
      // A light background: the picker says so beside the name.
      bool light = false;
    };

    // The presets and the configuration's named themes, ordered by the name they show. A named
    // theme that names a preset, or one of a preset's aliases, takes that preset's place.
    class ThemeCatalog {
    public:
      static constexpr std::size_t capacity = theme_presets.size() + runtime::config::ThemeReader::maximum_named_themes;

      // The presets alone.
      ThemeCatalog();

      // Adds or replaces the theme a configuration names; a later layer replaces an earlier one.
      void add(std::string_view name, const ThemeValues& values);

      [[nodiscard]] std::span<const ThemeEntry> entries() const noexcept;

      // The theme saved under `name`, as the configuration or a preset spells it, or under a
      // preset's alias.
      [[nodiscard]] const ThemeEntry* find(std::string_view name) const noexcept;

      // The entry a person typing `prefix` means: the first whose shown name starts with it,
      // ignoring case.
      [[nodiscard]] ds::Option<std::size_t> startingWith(std::string_view prefix) const noexcept;

    private:
      void insert(std::string_view name, std::string_view canonical, const ThemeValues& values);

      ds::Array<ThemeEntry, capacity> entries_;
      std::size_t count_ = 0;
    };

    // The name a theme shows: a preset's own, or the configured name with its words capitalized.
    void themeLabel(std::string_view name, runtime::FixedText<ThemeEntry::name_bytes>& label);

    // Whether a theme's background reads as light.
    [[nodiscard]] bool lightTheme(const ThemeValues& values) noexcept;

  }
}

// Interface: config/theme_command.cppm
export {
  namespace telar::gui::features::configuration {

    // `client.theme_picker.on_select`: the arguments it runs with, each ended by a NUL, and how
    // long it may run.
    class ThemeCommand {
    public:
      static constexpr std::size_t maximum_arguments = 32;
      static constexpr std::size_t argument_bytes = 4096 + maximum_arguments;
      static constexpr std::uint32_t default_timeout_ms = 2000;

      void append(std::string_view argument);
      void clear();

      [[nodiscard]] bool empty() const noexcept;
      [[nodiscard]] std::uint32_t timeoutMs() const noexcept;
      void setTimeoutMs(std::uint32_t timeout_ms) noexcept;

      // Hands each argument to `visit`, the theme's name in place of every one that is exactly
      // "{}" after the program.
      template <typename Visit>
      TBC_GENERIC void each(std::string_view theme, const Visit& visit) const {
        auto rest = text_.view();

        for (std::size_t index = 0; index < count_; ++index) {
          const auto end = rest.find('\0');
          const auto argument = rest.substr(0, end);

          visit(index > 0 && argument == "{}" ? theme : argument);
          rest.remove_prefix(end + 1);
        }
      }

    private:
      runtime::FixedText<argument_bytes> text_;
      std::size_t count_ = 0;
      std::uint32_t timeout_ms_ = default_timeout_ms;
    };

    // What the theme picker works with for one configuration.
    struct ThemePicker {
      ThemeCatalog catalog;
      ThemeCommand on_select;
    };

  }
}

// Interface: config/theme_choice.cppm
export {
  namespace telar::gui::features::configuration {

    // The theme a person chose in the picker, and a fingerprint of the configuration's theme it
    // was chosen over. The choice holds while the configuration still names that theme: editing
    // the configuration's theme makes the configuration win again.
    struct ThemeChoice {
      // The name, a newline, sixteen hexadecimal digits and a newline.
      static constexpr std::size_t file_bytes = ThemeEntry::name_bytes + 18;

      runtime::FixedText<ThemeEntry::name_bytes> name;
      std::uint64_t fingerprint = 0;

      // None for text that is not a choice this version wrote.
      [[nodiscard]] static ds::Option<ThemeChoice> parse(std::string_view text);

      // The file's text, written into `output`, region `a`.
      [[nodiscard]] tbc::val_a<std::string_view> format(tbc::mut_a<ds::Array<char, file_bytes>> output) const noexcept;

      bool operator==(const ThemeChoice&) const = default;
    };

    // A digest of every value of a configuration's theme selection, which a choice compares.
    [[nodiscard]] std::uint64_t themeFingerprint(const ThemeSelection& selection) noexcept;

  }
}
