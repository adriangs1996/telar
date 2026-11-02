#pragma once

#include "core/json_writer.hpp"
#include "core/theme_values.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

class ThemeQuery {
public:
  [[nodiscard]] static std::string_view write(const ThemeSelection &selection, std::span<char> output) {
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
  static void byteValue(JsonWriter &writer, ThemeRgb bytes) {
    writer.bytes(bytes);
  }

  static void writeColor(JsonWriter &writer, CellColor color) {
    constexpr std::array names{"default", "indexed", "rgb"};
    writer.object([&](JsonWriter &object) {
      object.member("kind", std::string_view{names[static_cast<std::size_t>(color.kind)]});
      object.member("value", [&](JsonWriter &value) {
        byteValue(value, color.channels);
      });
    });
  }

  static void writeTheme(JsonWriter &writer, const ThemeValues &theme) {
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

  static void writePalette(JsonWriter &writer, const ThemeValues &theme) {
    writer.object([&](JsonWriter &object) {
      for (std::size_t index = 0; index < palette_names.size(); ++index) {
        object.member(palette_names[index], [&](JsonWriter &value) {
          writeColor(value, theme.palette[index]);
        });
      }
    });
  }

  static void writeOptionalRgb(JsonWriter &writer, const std::optional<ThemeRgb> &color) {
    if (color) {
      byteValue(writer, *color);
    } else {
      writer.value(nullptr);
    }
  }

  static void writeTerminal(JsonWriter &writer, const TerminalThemeValues &terminal) {
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

  static void writeRgbPalette(JsonWriter &writer, std::span<const ThemeRgb> colors) {
    writer.array([&](JsonWriter &array) {
      for (const auto color : colors) {
        array.element([&](JsonWriter &value) {
          byteValue(value, color);
        });
      }
    });
  }

  static void writeSyntaxStyles(JsonWriter &writer, const ThemeValues &theme) {
    writer.object([&](JsonWriter &styles) {
      styles.member("values", [&](JsonWriter &items) {
        writeStyles(items, theme);
      });
    });
  }

  static void writeStyles(JsonWriter &writer, const ThemeValues &theme) {
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

  static void writeStyle(JsonWriter &writer, const SyntaxStyleValues &style) {
    writer.object([&](JsonWriter &object) {
      object.member("color", [&](JsonWriter &value) {
        writeColor(value, style.color);
      });
      object.member("italic", style.italic);
      object.member("bold", style.bold);
    });
  }

  static void writeOptionalTheme(JsonWriter &writer, const std::optional<ThemeValues> &theme) {
    if (theme) {
      writeTheme(writer, *theme);
    } else {
      writer.value(nullptr);
    }
  }
};

}
