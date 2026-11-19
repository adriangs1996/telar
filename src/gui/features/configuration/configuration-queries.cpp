module telar.gui.features.configuration;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.config.client;
import telar.config.gui;
import telar.config.runtime;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.base.ds;

namespace telar::gui::features::configuration {

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
      window.member("titlebar", configuration.titlebar.valueOr(default_titlebar));
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
    constexpr ds::Array names{"default", "indexed", "rgb"};

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

  void ThemeQuery::writeOptionalRgb(JsonWriter& writer, const ds::Option<ThemeRgb>& color) {
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

  void ThemeQuery::writeOptionalTheme(JsonWriter& writer, const ds::Option<ThemeValues>& theme) {
    if (theme) {
      writeTheme(writer, *theme);
    } else {
      writer.value(nullptr);
    }
  }

  BindingAction commandTabAction(runtime::config::CommandTabReference reference, std::uint64_t generation) noexcept {
    return {.kind = BindingActionKind::command_tab, .parameter = std::bit_cast<std::int32_t>(reference.epoch), .reference = reference.id, .generation = generation};
  }

  ds::Option<runtime::config::CommandTabReference> commandTabReference(BindingAction action) noexcept {
    if (action.kind != BindingActionKind::command_tab || !std::in_range<std::uint16_t>(action.reference)) {
      return ds::none;
    }

    return runtime::config::CommandTabReference{.epoch = std::bit_cast<std::uint32_t>(action.parameter), .id = static_cast<std::uint16_t>(action.reference)};
  }

  template <typename Value>
  void ActionQuery::writeValue(JsonWriter& writer, std::string_view type, const Value& value) {
    writer.object([&](JsonWriter& object) {
      object.member("type", type);
      object.member("value", value);
    });
  }

  template <Allocator Memory>
  void ActionQuery::write(JsonWriter& writer, BindingAction action, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands) {
    if (action.kind == BindingActionKind::command_tab) {
      const auto reference = commandTabReference(action);
      if (!reference) {
        throw std::runtime_error{"BindingNotFound"};
      }

      writeStoredCommand(writer, *reference, commands);
    } else if (action.kind == BindingActionKind::extended) {
      std::visit([&](const auto& description) {
        writeExtended(writer, description);
      },
          descriptions.at(action.parameter));
    } else if (action.kind == BindingActionKind::callback || action.kind == BindingActionKind::expression) {
      writeValue(writer, action.kind == BindingActionKind::callback ? "lua_callback" : "lua_expr", [&](JsonWriter& value) {
        value.object([&](JsonWriter& reference) {
          reference.member("generation", action.generation);
          reference.member("id", action.parameter);
        });
      });
    } else if (!writeNamed(writer, action.kind)) {
      writeNumeric(writer, action);
    }
  }

  template void ActionQuery::write<telar::Memory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

  template void ActionQuery::write<telar::ConcurrentMemory>(JsonWriter& writer, BindingAction action, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands);

  bool ActionQuery::writeNamed(JsonWriter& writer, BindingActionKind kind) {
    constexpr auto directions = ds::Array<NamedAction, 20>{{
        {.kind = BindingActionKind::scroll_pane_up, .type = "scroll_pane", .value = "up"},
        {.kind = BindingActionKind::scroll_pane_down, .type = "scroll_pane", .value = "down"},
        {.kind = BindingActionKind::split_horizontal, .type = "split_pane", .value = "horizontal"},
        {.kind = BindingActionKind::split_vertical, .type = "split_pane", .value = "vertical"},
        {.kind = BindingActionKind::focus_left, .type = "focus_pane", .value = "left"},
        {.kind = BindingActionKind::focus_right, .type = "focus_pane", .value = "right"},
        {.kind = BindingActionKind::focus_up, .type = "focus_pane", .value = "up"},
        {.kind = BindingActionKind::focus_down, .type = "focus_pane", .value = "down"},
        {.kind = BindingActionKind::navigate_left, .type = "navigate_pane", .value = "left"},
        {.kind = BindingActionKind::navigate_right, .type = "navigate_pane", .value = "right"},
        {.kind = BindingActionKind::navigate_up, .type = "navigate_pane", .value = "up"},
        {.kind = BindingActionKind::navigate_down, .type = "navigate_pane", .value = "down"},
        {.kind = BindingActionKind::resize_left, .type = "resize_pane", .value = "left"},
        {.kind = BindingActionKind::resize_right, .type = "resize_pane", .value = "right"},
        {.kind = BindingActionKind::resize_up, .type = "resize_pane", .value = "up"},
        {.kind = BindingActionKind::resize_down, .type = "resize_pane", .value = "down"},
        {.kind = BindingActionKind::resize_sidebar_left, .type = "resize_sidebar", .value = "left"},
        {.kind = BindingActionKind::resize_sidebar_right, .type = "resize_sidebar", .value = "right"},
        {.kind = BindingActionKind::move_tab_previous, .type = "move_tab", .value = "previous"},
        {.kind = BindingActionKind::move_tab_next, .type = "move_tab", .value = "next"},
    }};

    for (const auto& description : directions) {
      if (description.kind == kind) {
        writeValue(writer, description.type, description.value);

        return true;
      }
    }

    constexpr auto voids = ds::Array<std::pair<BindingActionKind, std::string_view>, 33>{{
        {BindingActionKind::toggle_pane_fullscreen, "toggle_pane_fullscreen"},
        {BindingActionKind::toggle_sidebar, "toggle_sidebar"},
        {BindingActionKind::toggle_workspace_list, "toggle_workspace_list"},
        {BindingActionKind::leave_worktree, "leave_worktree"},
        {BindingActionKind::forget_gone_worktrees, "forget_gone_worktrees"},
        {BindingActionKind::new_workspace, "new_workspace"},
        {BindingActionKind::rename_workspace, "rename_workspace"},
        {BindingActionKind::close_pane, "close_pane"},
        {BindingActionKind::new_tab, "new_tab"},
        {BindingActionKind::rename_tab, "rename_tab"},
        {BindingActionKind::close_tab, "close_tab"},
        {BindingActionKind::detach, "detach"},
        {BindingActionKind::goto_picker, "goto_picker"},
        {BindingActionKind::history_palette, "history_palette"},
        {BindingActionKind::path_picker, "path_picker"},
        {BindingActionKind::suggest_command, "suggest_command"},
        {BindingActionKind::close_panel, "close_panel"},
        {BindingActionKind::refresh_panel, "refresh_panel"},
        {BindingActionKind::machine_picker, "machine_picker"},
        {BindingActionKind::add_machine, "add_machine"},
        {BindingActionKind::copy_mode, "enter_copy_mode"},
        {BindingActionKind::monitor, "monitor"},
        {BindingActionKind::process_picker, "process_picker"},
        {BindingActionKind::process_terminate, "process_terminate"},
        {BindingActionKind::process_kill, "process_kill"},
        {BindingActionKind::process_stop, "process_stop"},
        {BindingActionKind::process_continue, "process_continue"},
        {BindingActionKind::process_lower_priority, "process_lower_priority"},
        {BindingActionKind::process_copy_command, "process_copy_command"},
        {BindingActionKind::process_focus_pane, "process_focus_pane"},
        {BindingActionKind::process_review_stack, "process_review_stack"},
        {BindingActionKind::process_review_files, "process_review_files"},
        {BindingActionKind::process_review_logs, "process_review_logs"},
    }};

    for (const auto& [action_kind, type] : voids) {
      if (kind == action_kind) {
        writeValue(writer, type, nullptr);

        return true;
      }
    }

    return false;
  }

  void ActionQuery::writeNumeric(JsonWriter& writer, BindingAction action) {
    switch (action.kind) {
    case BindingActionKind::select_tab:
      writeValue(writer, "select_tab", action.parameter);
      break;
    case BindingActionKind::select_workspace:
      writeValue(writer, "select_workspace", action.parameter);
      break;
    case BindingActionKind::select_tab_offset:
      writeValue(writer, "select_tab_offset", action.parameter);
      break;
    case BindingActionKind::next_tab:
    case BindingActionKind::previous_tab:
      writeValue(writer, "select_tab_offset", action.kind == BindingActionKind::next_tab ? 1 : -1);
      break;
    case BindingActionKind::next_machine:
    case BindingActionKind::previous_machine:
      writeValue(writer, "select_machine_offset", action.kind == BindingActionKind::next_machine ? 1 : -1);
      break;
    default:
      throw std::runtime_error{"BindingNotFound"};
    }
  }

  void ActionQuery::writeStoredCommand(JsonWriter& writer, runtime::config::CommandTabReference reference, const runtime::config::RetainedCommandTabRegistry& commands) {
    const auto command = commands.load(reference);
    if (!command) {
      throw std::runtime_error{"BindingNotFound"};
    }

    writeValue(writer, "command_tab", [&](JsonWriter& value) {
      writeCommand(value, *command);
    });
  }

  void ActionQuery::writeCommand(JsonWriter& writer, const runtime::config::CommandTabView& command) {
    writer.object([&](JsonWriter& object) {
      object.member("label", [&](JsonWriter& value) {
        value.bytes(byteView(command.label()));
      });

      object.member("argv", [&](JsonWriter& value) {
        writeArguments(value, command.argv());
      });
    });
  }

  void ActionQuery::writeArguments(JsonWriter& writer, std::span<const std::string_view> arguments) {
    writer.array([&](JsonWriter& array) {
      for (const auto argument : arguments) {
        array.element([&](JsonWriter& value) {
          value.bytes(byteView(argument));
        });
      }
    });
  }

  void ActionQuery::writeExtended(JsonWriter& writer, const NotificationActionDescription& description) {
    writeValue(writer, "notification", [&](JsonWriter& value) {
      writeNotification(value, description);
    });
  }

  void ActionQuery::writeNotification(JsonWriter& writer, const NotificationActionDescription& description) {
    constexpr ds::Array levels{"info", "success", "warning", "failure"};

    writer.object([&](JsonWriter& object) {
      object.member("title", description.title.view());
      object.member("message", description.message.view());
      object.member("level", std::string_view{levels[static_cast<std::size_t>(description.level)]});
      object.member("duration_ms", description.duration_ms);
      object.member("target", [&](JsonWriter& value) {
        writeTarget(value, description.target);
      });
    });
  }

  void ActionQuery::emptyObject(JsonWriter& writer) {
    writer.object([](JsonWriter&) {
    });
  }

  void ActionQuery::writeTarget(JsonWriter& writer, NotificationTarget target) {
    constexpr ds::Array targets{"none", "pane", "tab", "workspace"};

    writer.object([&](JsonWriter& object) {
      const auto name = std::string_view{targets[static_cast<std::size_t>(target.kind)]};

      if (target.kind == NotificationTarget::Kind::none) {
        object.member(name, emptyObject);
      } else {
        object.member(name, target.id);
      }
    });
  }

  void ActionQuery::writeExtended(JsonWriter& writer, DefinitionActionDescription description) {
    writeValue(writer, description.kind == DefinitionActionDescription::Kind::panel ? "open_panel" : "pick", description.index);
  }

  void ActionQuery::writeExtended(JsonWriter& writer, PluginActionDescription description) {
    writeValue(writer, "plugin", [&](JsonWriter& value) {
      value.object([&](JsonWriter& object) {
        object.member("plugin", description.plugin);
        object.member("action", description.action);
      });
    });
  }

  tbc::view<std::string_view, tbc::lt::a> InputQuery::write(const InputConfiguration& input, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("prefix", [&](JsonWriter& value) {
        writeKey(value, input.prefix);
      });

      object.member("sequence_timeout_ns", input.sequence_timeout_ns);
      object.member("binding_count", input.length);
    });

    return writer.view();
  }

  void InputQuery::writeKey(JsonWriter& writer, KeyChord key) {
    writer.object([&](JsonWriter& object) {
      object.member("code", [&](JsonWriter& value) {
        writeCode(value, key);
      });

      object.member("mods", [&](JsonWriter& value) {
        value.object([&](JsonWriter& modifiers) {
          modifiers.member("shift", key.has(KeyChord::Modifier::shift));
          modifiers.member("alt", key.has(KeyChord::Modifier::alt));
          modifiers.member("ctrl", key.has(KeyChord::Modifier::control));
          modifiers.member("super", key.has(KeyChord::Modifier::super));
        });
      });

      object.member("phase", "press");
      object.member("physical", nullptr);
      object.member("kitty", nullptr);
    });
  }

  void InputQuery::writeCode(JsonWriter& writer, KeyChord key) {
    writer.object([&](JsonWriter& object) {
      if (key.key != KeyChord::Key::character) {
        object.member(keyName(key.key), writeEmptyObject);

        return;
      }

      object.member("char", [&](JsonWriter& value) {
        writeCharacter(value, key);
      });
    });
  }

  void InputQuery::writeEmptyObject(JsonWriter& writer) {
    writer.object([](JsonWriter&) {
    });
  }

  void InputQuery::writeCharacter(JsonWriter& writer, KeyChord key) {
    const auto bytes = std::bit_cast<ds::Array<char, sizeof(key.character)>>(key.character);
    const auto first = static_cast<unsigned char>(bytes.front());
    std::size_t length = 1;

    while (length < Utf8Scalar::leading_prefixes.size() && first >= Utf8Scalar::leading_prefixes[length]) {
      ++length;
    }

    writer.object([&](JsonWriter& character) {
      character.member("bytes", std::string_view{bytes.data(), bytes.size()});
      character.member("len", length);
    });
  }

  std::string_view InputQuery::keyName(KeyChord::Key key) {
    constexpr ds::Array names{"char", "up", "down", "left", "right", "home", "end", "delete", "page_up", "page_down", "enter", "escape", "backspace", "tab", "back_tab"};
    const auto index = static_cast<std::size_t>(key);
    if (index >= names.size()) {
      throw std::invalid_argument{"Unknown key code"};
    }

    return names[index];
  }

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> BindingQuery::write(const InputConfiguration& input, std::size_t index, const ActionDescriptions<Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output) {
    if (index >= input.length) {
      throw std::runtime_error{"BindingNotFound"};
    }

    const auto& binding = input.configured[index];
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("index", index);
      object.member("prefixed", binding.prefixed);
      object.member("keys", [&](JsonWriter& value) {
        writeKeys(value, binding.sequence());
      });

      object.member("action", [&](JsonWriter& value) {
        ActionQuery::write(value, binding.action, descriptions, commands);
      });
    });

    return writer.view();
  }

  template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::Memory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::Memory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

  template tbc::view<std::string_view, tbc::lt::a> BindingQuery::write<telar::ConcurrentMemory>(const InputConfiguration& input, std::size_t index, const ActionDescriptions<telar::ConcurrentMemory>& descriptions, const runtime::config::RetainedCommandTabRegistry& commands, tbc::view<std::span<char>, tbc::lt::a> output);

  void BindingQuery::writeKeys(JsonWriter& writer, std::span<const KeyChord> keys) {
    writer.array([&](JsonWriter& array) {
      for (const auto key : keys) {
        array.element([&](JsonWriter& value) {
          InputQuery::writeKey(value, key);
        });
      }
    });
  }

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> RuntimeQuery::write(const runtime::config::RuntimeValues<Memory>& values, tbc::view<std::span<char>, tbc::lt::a> output) {
    JsonWriter writer{output};

    writer.object([&](JsonWriter& object) {
      object.member("graphics_pane_bytes", values.graphics.pane_bytes);
      object.member("graphics_global_bytes", values.graphics.global_bytes);
      object.member("history_path", nullablePath(values.history_path));
      object.member("history_output_capture", values.capture_output);
      object.member("session_path", nullablePath(values.session_path));
      object.member("session_persist", values.persist_session);
      object.member("session_resume_agents", values.resume_agents);
      writeProxy(object, values.proxy);
      object.member("engine_idle_timeout_ms", values.engine.idle_timeout.count());
      object.member("agent_manifest_count", values.manifests.entries().size());
    });

    return writer.view();
  }

  ds::Option<std::string_view> RuntimeQuery::nullablePath(std::string_view path) noexcept {
    return path.empty() ? ds::none : ds::Option{path};
  }

  template <Allocator Memory>
  void RuntimeQuery::writeProxy(JsonWriter& writer, const runtime::ProxyOptions<Memory>& proxy) {
    writer.member("proxy_enabled", proxy.enabled);
    writer.member("proxy_anonymous_tunnels", proxy.anonymous_tunnels);
    writer.member("proxy_ca_dir", nullablePath(proxy.authority_directory));
    writer.member("proxy_intercept_hosts", [&](JsonWriter& value) {
      value.array([&](JsonWriter& array) {
        for (const auto& host : proxy.intercept_hosts.patterns()) {
          array.element(std::string_view{host});
        }
      });
    });

    writer.member("proxy_capture_enabled", proxy.capture.enabled);
    writer.member("proxy_capture_max_part_bytes", proxy.capture.part_bytes);
    writer.member("proxy_capture_max_exchange_bytes", proxy.capture.exchange_bytes);
    writer.member("proxy_capture_max_total_bytes", proxy.capture.total_bytes);
    writer.member("proxy_capture_join_timeout_ms", proxy.capture.join_timeout.count());
  }

  template tbc::view<std::string_view, tbc::lt::a> RuntimeQuery::write<telar::Memory>(const runtime::config::RuntimeValues<telar::Memory>& values, tbc::view<std::span<char>, tbc::lt::a> output);

  template tbc::view<std::string_view, tbc::lt::a> RuntimeQuery::write<telar::ConcurrentMemory>(const runtime::config::RuntimeValues<telar::ConcurrentMemory>& values, tbc::view<std::span<char>, tbc::lt::a> output);

}
