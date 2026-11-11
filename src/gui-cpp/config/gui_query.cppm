module;
#include "tbc/view.hpp"
#include <cstdio>

#include <cstddef>
#include <cstdint>

#include <cmath>
#include <cstring>

export module telar.gui.config.gui_query;

import std;

export import telar.gui.application.host_effects;
export import telar.gui.core.metrics;
export import telar.gui.core.json_writer;


export import telar.gui.input.copy_pointer;
export import telar.gui.input.key_encoder;
import telar.base.diagnostics;
import telar.client.protocol;

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

  [[nodiscard]] inline static ConfigurationQuery parse(std::string_view name, std::int64_t index) {
    if (name.empty()) {
      return {.section = Section::client, .index = index};
    }

    for (const auto &[known, section] : sections) {
      if (name == known) {
        return {.section = section, .index = index};
      }
    }

    throw std::invalid_argument{"UnknownConfigurationSection"};
  }
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
  [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> write(const Configuration &configuration, const ClientQueryContext &context, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("source", [&](JsonWriter &value) {
        writeOptionalBytes(value, context.source);
      });
      object.member("profile", [&](JsonWriter &value) {
        writeOptionalBytes(value, context.profile);
      });
      object.member("generation", context.generation);
      object.member("sidebar_visible", context.view.sidebar_visible);
      object.member("sidebar_width", context.view.sidebar_width);
      object.member("workspace_list_collapsed", context.view.workspace_list_collapsed);
      object.member("pane_gaps", context.view.pane_gaps);
      object.member("window_title", context.view.window_title);
      object.member("sound", [&](JsonWriter &value) {
        writeSound(value, configuration.sound);
      });
      object.member("notification_delivery", configuration.notification_delivery == NotificationDelivery::system ? "system" : "telar");
      object.member("history_show_agent_commands", configuration.history.show_agent_commands);
      object.member("history_enter_runs", configuration.history.enter_runs);
      object.member("history_match_fts", configuration.history.match_fts);
      object.member("sections", writeSections);
    });

    return writer.view();
  }

private:
  inline static void writeOptionalBytes(JsonWriter &writer, std::optional<std::string_view> text) {
    if (text) {
      writer.bytes(byteView(*text));
    } else {
      writer.value(nullptr);
    }
  }

  inline static void writeSound(JsonWriter &writer, SoundPolicy policy) {
    writer.object([&](JsonWriter &object) {
      object.member("enabled", policy.enabled);
      object.member("ready", policy.ready);
      object.member("needs_input", policy.needs_input);
    });
  }

  inline static void writeSections(JsonWriter &writer) {
    writer.array([](JsonWriter &sections) {
      for (const auto &[name, section] : ConfigurationQuery::sections) {
        sections.element(name);
      }
    });
  }
};

}
}

// Interface: config/default_bindings.cppm
export {
#include "default_bindings.inc"
}

// Interface: config/gui_query.cppm
export {
namespace telar::gui {

class GuiQuery {
public:
  [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> write(const Configuration &configuration, tbc::view<std::span<char>, tbc::lt::a> output, bool default_titlebar) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("font", [&](JsonWriter &value) {
        writeFont(value, configuration.font);
      });
      object.member("cursor", [&](JsonWriter &value) {
        value.object([&](JsonWriter &cursor) {
          cursor.member("style", cursorStyle(configuration.cursor));
          cursor.member("blink", configuration.cursor_blink);
          cursor.member("blink_interval_ms", configuration.blink_interval.count());
        });
      });
      object.member("scroll", [&](JsonWriter &value) {
        value.object([&](JsonWriter &scroll) {
          scroll.member("smooth", configuration.scroll.smooth);
          scroll.member("wheel_ms", configuration.scroll.wheel_ms);
          scroll.member("overscan", configuration.scroll.overscan);
          scroll.member("sticky_headers", configuration.scroll.sticky_headers);
        });
      });
      object.member("window", [&](JsonWriter &value) {
        writeWindow(value, configuration, default_titlebar);
      });
      object.member("opacity", [&](JsonWriter &value) {
        value.object([&](JsonWriter &opacity) {
          for (std::size_t index = 0; index < BackgroundOpacity::names.size(); ++index) {
            opacity.member(BackgroundOpacity::names[index], configuration.opacity.resolve(static_cast<BackgroundOpacity::Surface>(index), configuration.background_opacity));
          }
        });
      });
      object.member("chrome", [&](JsonWriter &value) {
        value.object([&](JsonWriter &chrome) {
          chrome.member("scale", configuration.chrome_scale);
        });
      });
      object.member("sidebar", [&](JsonWriter &value) {
        value.object([&](JsonWriter &sidebar) {
          sidebar.member("width", configuration.sidebar_width);
        });
      });
    });

    return writer.view();
  }

private:
  inline static void writeFont(JsonWriter &writer, const FontConfiguration &font) {
    writer.object([&](JsonWriter &object) {
      object.member("family", font.family.view());
      object.member("style", font.style.view());
      object.member("size", font.size);
      object.member("line_height", font.line_height);
      object.member("letter_spacing", font.letter_spacing);
      object.member("thicken", font.thicken);
      object.member("thicken_strength", font.thicken_strength);
    });
  }

  inline static void writeWindow(JsonWriter &writer, const Configuration &configuration, bool default_titlebar) {
    writer.object([&](JsonWriter &window) {
      window.member("background_opacity", configuration.background_opacity);
      window.member("background_blur", configuration.background_blur);
      window.member("titlebar", configuration.titlebar.value_or(default_titlebar));
      window.member("padding", [&](JsonWriter &value) {
        value.object([&](JsonWriter &padding) {
          padding.member("x", configuration.padding_x);
          padding.member("y", configuration.padding_y);
        });
      });
    });
  }

  inline static std::string_view cursorStyle(CursorShape cursor) {
    switch (cursor) {
    case CursorShape::block:
      return "block";
    case CursorShape::bar:
      return "bar";
    case CursorShape::underline:
      return "underline";
    case CursorShape::hollow:
      return "hollow";
    case CursorShape::default_shape:
      break;
    }

    throw std::invalid_argument{"Unknown cursor shape"};
  }
};

}
}

// Interface: config/palette_actions.cppm
export {
#include "palette_actions.inc"
}

// Interface: config/theme_presets.cppm
export {
#include "theme_presets.inc"
}

// Interface: config/theme_query.cppm
export {
namespace telar::gui {

class ThemeQuery {
public:
  [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> write(const ThemeSelection &selection, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("base", [&](JsonWriter &value) {
        writeTheme(value, selection.base);
      });
      object.member("light", [&](JsonWriter &value) {
        writeOptionalTheme(value, selection.light);
      });
      object.member("dark", [&](JsonWriter &value) {
        writeOptionalTheme(value, selection.dark);
      });
    });

    return writer.view();
  }

private:
  inline static void byteValue(JsonWriter &writer, ThemeRgb bytes) {
    writer.bytes(bytes);
  }

  inline static void writeColor(JsonWriter &writer, CellColor color) {
    constexpr std::array names{"default", "indexed", "rgb"};
    writer.object([&](JsonWriter &object) {
      object.member("kind", std::string_view{names[static_cast<std::size_t>(color.kind)]});
      object.member("value", [&](JsonWriter &value) {
        byteValue(value, color.channels);
      });
    });
  }

  inline static void writeTheme(JsonWriter &writer, const ThemeValues &theme) {
    writer.object([&](JsonWriter &object) {
      object.member("base", std::string_view{theme_names[static_cast<std::size_t>(theme.base)]});
      object.member("palette", [&](JsonWriter &value) {
        writePalette(value, theme);
      });
      object.member("terminal", [&](JsonWriter &value) {
        writeTerminal(value, theme.terminal);
      });
      object.member("syntax_styles", [&](JsonWriter &value) {
        writeSyntaxStyles(value, theme);
      });
    });
  }

  inline static void writePalette(JsonWriter &writer, const ThemeValues &theme) {
    writer.object([&](JsonWriter &object) {
      for (std::size_t index = 0; index < palette_names.size(); ++index) {
        object.member(palette_names[index], [&](JsonWriter &value) {
          writeColor(value, theme.palette[index]);
        });
      }
    });
  }

  inline static void writeOptionalRgb(JsonWriter &writer, const std::optional<ThemeRgb> &color) {
    if (color) {
      byteValue(writer, *color);
    } else {
      writer.value(nullptr);
    }
  }

  inline static void writeTerminal(JsonWriter &writer, const TerminalThemeValues &terminal) {
    writer.object([&](JsonWriter &object) {
      object.member("foreground", [&](JsonWriter &value) {
        byteValue(value, terminal.foreground);
      });
      object.member("background", [&](JsonWriter &value) {
        byteValue(value, terminal.background);
      });
      object.member("cursor_color", [&](JsonWriter &value) {
        writeOptionalRgb(value, terminal.cursor_color);
      });
      object.member("cursor_text_color", [&](JsonWriter &value) {
        writeOptionalRgb(value, terminal.cursor_text_color);
      });
      object.member("palette", [&](JsonWriter &value) {
        writeRgbPalette(value, terminal.palette);
      });
    });
  }

  inline static void writeRgbPalette(JsonWriter &writer, std::span<const ThemeRgb> colors) {
    writer.array([&](JsonWriter &array) {
      for (const auto color : colors) {
        array.element([&](JsonWriter &value) {
          byteValue(value, color);
        });
      }
    });
  }

  inline static void writeSyntaxStyles(JsonWriter &writer, const ThemeValues &theme) {
    writer.object([&](JsonWriter &styles) {
      styles.member("values", [&](JsonWriter &items) {
        writeStyles(items, theme);
      });
    });
  }

  inline static void writeStyles(JsonWriter &writer, const ThemeValues &theme) {
    writer.array([&](JsonWriter &array) {
      for (const auto &style : theme.syntax_styles) {
        if (!style) {
          array.element(nullptr);

          continue;
        }

        array.element([&](JsonWriter &value) {
          writeStyle(value, *style);
        });
      }
    });
  }

  inline static void writeStyle(JsonWriter &writer, const SyntaxStyleValues &style) {
    writer.object([&](JsonWriter &object) {
      object.member("color", [&](JsonWriter &value) {
        writeColor(value, style.color);
      });
      object.member("italic", style.italic);
      object.member("bold", style.bold);
    });
  }

  inline static void writeOptionalTheme(JsonWriter &writer, const std::optional<ThemeValues> &theme) {
    if (theme) {
      writeTheme(writer, *theme);
    } else {
      writer.value(nullptr);
    }
  }
};

}
}
