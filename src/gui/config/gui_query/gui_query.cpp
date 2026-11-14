module telar.gui.config.gui_query;

namespace telar::gui {

  ConfigurationQuery ConfigurationQuery::parse(std::string_view name, std::int64_t index) {
    if (name.empty()) {
      return {.section = Section::client, .index = index};
    }

    for (const auto& [known, section] : sections) {
      if (name == known) {
        return {.section = section, .index = index};
      }
    }

    throw std::invalid_argument{"UnknownConfigurationSection"};
  }

  tbc::view<std::string_view, tbc::lt::a> ClientQuery::write(const Configuration& configuration, const ClientQueryContext& context, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("source", [&](JsonWriter& value) {
        writeOptionalBytes(value, context.source);
      });

      object.member("profile", [&](JsonWriter& value) {
        writeOptionalBytes(value, context.profile);
      });

      object.member("generation", context.generation);
      object.member("sidebar_visible", context.view.sidebar_visible);
      object.member("sidebar_width", context.view.sidebar_width);
      object.member("workspace_list_collapsed", context.view.workspace_list_collapsed);
      object.member("pane_gaps", context.view.pane_gaps);
      object.member("window_title", context.view.window_title);
      object.member("sound", [&](JsonWriter& value) {
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

  void ClientQuery::writeOptionalBytes(JsonWriter& writer, std::optional<std::string_view> text) {
    if (text) {
      writer.bytes(byteView(*text));
    } else {
      writer.value(nullptr);
    }
  }

  void ClientQuery::writeSound(JsonWriter& writer, SoundPolicy policy) {
    writer.object([&](JsonWriter& object) {
      object.member("enabled", policy.enabled);
      object.member("ready", policy.ready);
      object.member("needs_input", policy.needs_input);
    });
  }

  void ClientQuery::writeSections(JsonWriter& writer) {
    writer.array([](JsonWriter& sections) {
      for (const auto& [name, section] : ConfigurationQuery::sections) {
        sections.element(name);
      }
    });
  }

  tbc::view<std::string_view, tbc::lt::a> GuiQuery::write(const Configuration& configuration, tbc::view<std::span<char>, tbc::lt::a> output, bool default_titlebar) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("font", [&](JsonWriter& value) {
        writeFont(value, configuration.font);
      });

      object.member("cursor", [&](JsonWriter& value) {
        value.object([&](JsonWriter& cursor) {
          cursor.member("style", cursorStyle(configuration.cursor));
          cursor.member("blink", configuration.cursor_blink);
          cursor.member("blink_interval_ms", configuration.blink_interval.count());
        });
      });

      object.member("scroll", [&](JsonWriter& value) {
        value.object([&](JsonWriter& scroll) {
          scroll.member("smooth", configuration.scroll.smooth);
          scroll.member("wheel_ms", configuration.scroll.wheel_ms);
          scroll.member("overscan", configuration.scroll.overscan);
          scroll.member("sticky_headers", configuration.scroll.sticky_headers);
        });
      });

      object.member("window", [&](JsonWriter& value) {
        writeWindow(value, configuration, default_titlebar);
      });

      object.member("opacity", [&](JsonWriter& value) {
        value.object([&](JsonWriter& opacity) {
          for (std::size_t index = 0; index < BackgroundOpacity::names.size(); ++index) {
            opacity.member(BackgroundOpacity::names[index], configuration.opacity.resolve(static_cast<BackgroundOpacity::Surface>(index), configuration.background_opacity));
          }
        });
      });

      object.member("chrome", [&](JsonWriter& value) {
        value.object([&](JsonWriter& chrome) {
          chrome.member("scale", configuration.chrome_scale);
        });
      });

      object.member("sidebar", [&](JsonWriter& value) {
        value.object([&](JsonWriter& sidebar) {
          sidebar.member("width", configuration.sidebar_width);
        });
      });
    });

    return writer.view();
  }

  void GuiQuery::writeFont(JsonWriter& writer, const FontConfiguration& font) {
    writer.object([&](JsonWriter& object) {
      object.member("family", font.family.view());
      object.member("style", font.style.view());
      object.member("size", font.size);
      object.member("line_height", font.line_height);
      object.member("letter_spacing", font.letter_spacing);
      object.member("thicken", font.thicken);
      object.member("thicken_strength", font.thicken_strength);
      object.member("hinting", runtime::config::font_hinting_names.at(std::to_underlying(font.hinting)));
    });
  }

  void GuiQuery::writeWindow(JsonWriter& writer, const Configuration& configuration, bool default_titlebar) {
    writer.object([&](JsonWriter& window) {
      window.member("background_opacity", configuration.background_opacity);
      window.member("background_blur", configuration.background_blur);
      window.member("titlebar", configuration.titlebar.value_or(default_titlebar));
      window.member("padding", [&](JsonWriter& value) {
        value.object([&](JsonWriter& padding) {
          padding.member("x", configuration.padding_x);
          padding.member("y", configuration.padding_y);
        });
      });
    });
  }

  std::string_view GuiQuery::cursorStyle(CursorShape cursor) {
    if (cursor == CursorShape::default_shape) {
      throw std::invalid_argument{"Unknown cursor shape"};
    }

    return runtime::config::cursor_style_names.at(std::to_underlying(cursor) - 1);
  }

  tbc::view<std::string_view, tbc::lt::a> ThemeQuery::write(const ThemeSelection& selection, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("base", [&](JsonWriter& value) {
        writeTheme(value, selection.base);
      });

      object.member("light", [&](JsonWriter& value) {
        writeOptionalTheme(value, selection.light);
      });

      object.member("dark", [&](JsonWriter& value) {
        writeOptionalTheme(value, selection.dark);
      });
    });

    return writer.view();
  }

  void ThemeQuery::byteValue(JsonWriter& writer, ThemeRgb bytes) {
    writer.bytes(bytes);
  }

  void ThemeQuery::writeColor(JsonWriter& writer, CellColor color) {
    constexpr std::array names{"default", "indexed", "rgb"};

    writer.object([&](JsonWriter& object) {
      object.member("kind", std::string_view{names[static_cast<std::size_t>(color.kind)]});
      object.member("value", [&](JsonWriter& value) {
        byteValue(value, color.channels);
      });
    });
  }

  void ThemeQuery::writeTheme(JsonWriter& writer, const ThemeValues& theme) {
    writer.object([&](JsonWriter& object) {
      object.member("base", std::string_view{theme_names[static_cast<std::size_t>(theme.base)]});
      object.member("palette", [&](JsonWriter& value) {
        writePalette(value, theme);
      });

      object.member("terminal", [&](JsonWriter& value) {
        writeTerminal(value, theme.terminal);
      });

      object.member("syntax_styles", [&](JsonWriter& value) {
        writeSyntaxStyles(value, theme);
      });
    });
  }

  void ThemeQuery::writePalette(JsonWriter& writer, const ThemeValues& theme) {
    writer.object([&](JsonWriter& object) {
      for (std::size_t index = 0; index < palette_names.size(); ++index) {
        object.member(palette_names[index], [&](JsonWriter& value) {
          writeColor(value, theme.palette[index]);
        });
      }
    });
  }

  void ThemeQuery::writeOptionalRgb(JsonWriter& writer, const std::optional<ThemeRgb>& color) {
    if (color) {
      byteValue(writer, *color);
    } else {
      writer.value(nullptr);
    }
  }

  void ThemeQuery::writeTerminal(JsonWriter& writer, const TerminalThemeValues& terminal) {
    writer.object([&](JsonWriter& object) {
      object.member("foreground", [&](JsonWriter& value) {
        byteValue(value, terminal.foreground);
      });

      object.member("background", [&](JsonWriter& value) {
        byteValue(value, terminal.background);
      });

      object.member("cursor_color", [&](JsonWriter& value) {
        writeOptionalRgb(value, terminal.cursor_color);
      });

      object.member("cursor_text_color", [&](JsonWriter& value) {
        writeOptionalRgb(value, terminal.cursor_text_color);
      });

      object.member("palette", [&](JsonWriter& value) {
        writeRgbPalette(value, terminal.palette);
      });
    });
  }

  void ThemeQuery::writeRgbPalette(JsonWriter& writer, std::span<const ThemeRgb> colors) {
    writer.array([&](JsonWriter& array) {
      for (const auto color : colors) {
        array.element([&](JsonWriter& value) {
          byteValue(value, color);
        });
      }
    });
  }

  void ThemeQuery::writeSyntaxStyles(JsonWriter& writer, const ThemeValues& theme) {
    writer.object([&](JsonWriter& styles) {
      styles.member("values", [&](JsonWriter& items) {
        writeStyles(items, theme);
      });
    });
  }

  void ThemeQuery::writeStyles(JsonWriter& writer, const ThemeValues& theme) {
    writer.array([&](JsonWriter& array) {
      for (const auto& style : theme.syntax_styles) {
        if (!style) {
          array.element(nullptr);

          continue;
        }

        array.element([&](JsonWriter& value) {
          writeStyle(value, *style);
        });
      }
    });
  }

  void ThemeQuery::writeStyle(JsonWriter& writer, const SyntaxStyleValues& style) {
    writer.object([&](JsonWriter& object) {
      object.member("color", [&](JsonWriter& value) {
        writeColor(value, style.color);
      });

      object.member("italic", style.italic);
      object.member("bold", style.bold);
    });
  }

  void ThemeQuery::writeOptionalTheme(JsonWriter& writer, const std::optional<ThemeValues>& theme) {
    if (theme) {
      writeTheme(writer, *theme);
    } else {
      writer.value(nullptr);
    }
  }

}
