#pragma once

#include "core/configuration.hpp"
#include "presentation/theme.hpp"
#include "telar_config/gui_validator.hpp"
#include "telar_config/theme_validator.hpp"
#include "telar_config/value_constraints.hpp"
#include "theme_reader.hpp"
#include "themes.hpp"

namespace telar::gui {

class ConfigurationReader {
public:
  static Configuration read(const runtime::lua::Value &root, std::string_view profile) {
    root.onlyFields({"api_version", "theme", "client", "gui", "runtime", "plugins", "profiles"});
    if (root.field("api_version").integer() != 2) {
      root.fail("requires api_version = 2");
    }

    Configuration result;
    result.themes.base = default_theme_values;
    apply(root, result);

    if (!profile.empty()) {
      const auto profiles = root.field("profiles");
      if (!profiles.present()) {
        profiles.fail("does not define the selected profile");
      }

      const auto selected = profiles.entry(profile);
      if (!selected.present()) {
        selected.fail("is not defined");
      }

      apply(selected, result);
    }

    result.theme = projectTheme(result.themes.base);

    return result;
  }

private:
  using Value = runtime::lua::Value;

  static void apply(const Value &root, Configuration &configuration) {
    runtime::config::ThemeValidator::selection(root);
    ThemeReader::apply(root, configuration.themes);
    client(root.field("client"), configuration);

    const auto gui = root.field("gui");
    runtime::config::GuiValidator::validate(gui);
    if (!gui.present()) {
      return;
    }

    font(gui.field("font"), configuration.font);
    const auto cursor = gui.field("cursor");
    if (cursor.present()) {
      const auto style = cursor.field("style");
      if (style.present()) {
        configuration.cursor = cursorShape(style.string());
      }

      configuration.cursor_blink = cursor.field("blink").boolean(configuration.cursor_blink);
      configuration.blink_interval = std::chrono::milliseconds{cursor.field("blink_interval_ms").boundedInteger(configuration.blink_interval.count(), Configuration::minimum_blink_interval.count(), Configuration::maximum_blink_interval.count())};
    }

    window(gui.field("window"), configuration);
    const auto chrome = gui.field("chrome");
    if (chrome.present()) {
      configuration.chrome_scale = static_cast<float>(chrome.field("scale").boundedNumber(configuration.chrome_scale, Configuration::minimum_chrome_scale, Configuration::maximum_chrome_scale));
    }

    const auto sidebar = gui.field("sidebar");
    if (sidebar.present()) {
      configuration.sidebar_width = static_cast<float>(sidebar.field("width").boundedNumber(configuration.sidebar_width, Configuration::minimum_sidebar_width, Configuration::maximum_sidebar_width));
    }

    const auto fps = gui.field("max_fps");
    if (fps.present()) {
      configuration.max_fps = static_cast<std::uint16_t>(fps.boundedInteger(configuration.max_fps, Configuration::minimum_fps, Configuration::maximum_fps));
    }
  }

  static void client(const Value &table, Configuration &configuration) {
    if (!table.present()) {
      return;
    }

    const auto sidebar = table.field("sidebar");
    if (sidebar.present()) {
      configuration.sidebar_visible = sidebar.field("visible").boolean(configuration.sidebar_visible);
    }

    configuration.pane_gaps = table.field("pane_gaps").boolean(configuration.pane_gaps);
    const auto editor = table.field("editor");
    if (editor.present()) {
      DisplayText16<Configuration::maximum_editor_bytes, false>::validate(editor.string());
      configuration.editor.assign(editor.string());
    }

    const auto window_title = table.field("window_title");
    if (window_title.present()) {
      DisplayText16<Configuration::maximum_window_title_bytes, true>::validate(window_title.string());
      configuration.window_title.assign(window_title.string());
    }

    history(table.field("history"), configuration.history);
    sound(table.field("sound"), configuration.sound);
    const auto notifications = table.field("notifications");
    if (notifications.present()) {
      notifications.onlyFields({"delivery"});
      const auto delivery = notifications.field("delivery");
      runtime::config::optionalChoice(delivery, {"telar", "system", "terminal"});
      if (delivery.present() && delivery.string() != "terminal") {
        configuration.notification_delivery = delivery.string() == "system" ? NotificationDelivery::system : NotificationDelivery::telar;
      }
    }
  }

  static void sound(const Value &table, SoundPolicy &policy) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "ready", "needs_input"});
    policy.enabled = table.field("enabled").boolean(policy.enabled);
    policy.ready = table.field("ready").boolean(policy.ready);
    policy.needs_input = table.field("needs_input").boolean(policy.needs_input);
  }

  static void history(const Value &table, HistoryConfiguration &history) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"show_agent_commands", "enter", "match"});
    history.show_agent_commands = table.field("show_agent_commands").boolean(history.show_agent_commands);
    const auto enter = table.field("enter");
    const auto match = table.field("match");
    runtime::config::optionalChoice(enter, {"paste", "run"});
    runtime::config::optionalChoice(match, {"fuzzy", "fts"});
    if (enter.present()) {
      history.enter_runs = enter.string() == "run";
    }

    if (match.present()) {
      history.match_fts = match.string() == "fts";
    }
  }

  static void font(const Value &table, FontConfiguration &font) {
    if (!table.present()) {
      return;
    }

    const auto family = table.field("family");
    const auto style = table.field("style");
    if (family.present()) {
      font.family.assign(family.string());
    }

    if (style.present()) {
      font.style.assign(style.string());
    }

    font.size = static_cast<float>(table.field("size").boundedNumber(font.size, FontConfiguration::minimum_size, FontConfiguration::maximum_size));
    font.line_height = static_cast<float>(table.field("line_height").boundedNumber(font.line_height, FontConfiguration::minimum_line_height, FontConfiguration::maximum_line_height));
    font.letter_spacing = static_cast<float>(table.field("letter_spacing").boundedNumber(font.letter_spacing, FontConfiguration::minimum_letter_spacing, FontConfiguration::maximum_letter_spacing));
    font.thicken = table.field("thicken").boolean(font.thicken);
    font.thicken_strength = static_cast<std::uint8_t>(table.field("thicken_strength").boundedInteger(font.thicken_strength, 0, FontConfiguration::maximum_thicken_strength));
  }

  static void window(const Value &table, Configuration &configuration) {
    if (!table.present()) {
      return;
    }

    configuration.background_opacity = static_cast<float>(table.field("background_opacity").boundedNumber(configuration.background_opacity, 0, 1));
    const auto titlebar = table.field("titlebar");
    if (titlebar.present()) {
      configuration.titlebar = titlebar.boolean(true);
    }

    const auto blur = table.field("background_blur");
    if (blur.present()) {
      if (blur.is(LUA_TBOOLEAN)) {
        configuration.background_blur = blur.boolean(false) ? Configuration::default_background_blur : 0;
      } else {
        configuration.background_blur = static_cast<std::uint8_t>(blur.boundedInteger(configuration.background_blur, 0, Configuration::maximum_background_blur));
      }
    }

    const auto padding = table.field("padding");
    if (padding.present()) {
      configuration.padding_x = static_cast<float>(padding.field("x").boundedNumber(configuration.padding_x, 0, Configuration::maximum_padding));
      configuration.padding_y = static_cast<float>(padding.field("y").boundedNumber(configuration.padding_y, 0, Configuration::maximum_padding));
    }
  }

  static CursorShape cursorShape(std::string_view name) noexcept {
    if (name == "bar") {
      return CursorShape::bar;
    }

    if (name == "underline") {
      return CursorShape::underline;
    }

    if (name == "hollow") {
      return CursorShape::hollow;
    }

    return CursorShape::block;
  }
};

}
