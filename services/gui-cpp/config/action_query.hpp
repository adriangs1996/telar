#pragma once

#include "action_descriptions.hpp"
#include "command_tab_action.hpp"
#include "core/json_writer.hpp"
#include "core/memory.hpp"
#include "input/action.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/command_tab_reference.hpp"
#include "telar_config/command_tab_registry.hpp"
#include "telar_config/command_tab_view.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <variant>

namespace telar::gui {

class ActionQuery {
public:
  template <Allocator Memory>
  static void write(JsonWriter &writer, BindingAction action, const ActionDescriptions<Memory> &descriptions, const runtime::config::RetainedCommandTabRegistry &commands) {
    if (action.kind == BindingActionKind::command_tab) {
      const auto reference = commandTabReference(action);
      if (!reference) {
        throw std::runtime_error{"BindingNotFound"};
      }

      writeStoredCommand(writer, *reference, commands);
    } else if (action.kind == BindingActionKind::extended) {
      std::visit([&](const auto &description) {
        writeExtended(writer, description);
      },
                 descriptions.at(action.parameter));
    } else if (action.kind == BindingActionKind::callback || action.kind == BindingActionKind::expression) {
      writeValue(writer, action.kind == BindingActionKind::callback ? "lua_callback" : "lua_expr", [&](JsonWriter &value) {
        value.object([&](JsonWriter &reference) {
          reference.member("generation", action.generation);
          reference.member("id", action.parameter);
        });
      });
    } else if (!writeNamed(writer, action.kind)) {
      writeNumeric(writer, action);
    }
  }

private:
  template <typename Value>
  static void writeValue(JsonWriter &writer, std::string_view type, const Value &value) {
    writer.object([&](JsonWriter &object) {
      object.member("type", type);
      object.member("value", value);
    });
  }

  struct NamedAction {
    BindingActionKind kind;
    std::string_view type;
    std::string_view value;
  };

  static bool writeNamed(JsonWriter &writer, BindingActionKind kind) {
    constexpr auto directions = std::to_array<NamedAction>({
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
    });
    for (const auto &description : directions) {
      if (description.kind == kind) {
        writeValue(writer, description.type, description.value);

        return true;
      }
    }

    constexpr auto voids = std::to_array<std::pair<BindingActionKind, std::string_view>>({
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
    });
    for (const auto &[action_kind, type] : voids) {
      if (kind == action_kind) {
        writeValue(writer, type, nullptr);

        return true;
      }
    }

    return false;
  }

  static void writeNumeric(JsonWriter &writer, BindingAction action) {
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

  static void writeStoredCommand(JsonWriter &writer, runtime::config::CommandTabReference reference, const runtime::config::RetainedCommandTabRegistry &commands) {
    const auto command = commands.load(reference);
    if (!command) {
      throw std::runtime_error{"BindingNotFound"};
    }

    writeValue(writer, "command_tab", [&](JsonWriter &value) {
      writeCommand(value, *command);
    });
  }

  static void writeCommand(JsonWriter &writer, const runtime::config::CommandTabView &command) {
    writer.object([&](JsonWriter &object) {
      object.member("label", [&](JsonWriter &value) {
        value.bytes(byteView(command.label()));
      });
      object.member("argv", [&](JsonWriter &value) {
        writeArguments(value, command.argv());
      });
    });
  }

  static void writeArguments(JsonWriter &writer, std::span<const std::string_view> arguments) {
    writer.array([&](JsonWriter &array) {
      for (const auto argument : arguments) {
        array.element([&](JsonWriter &value) {
          value.bytes(byteView(argument));
        });
      }
    });
  }

  static void writeExtended(JsonWriter &writer, const NotificationActionDescription &description) {
    writeValue(writer, "notification", [&](JsonWriter &value) {
      writeNotification(value, description);
    });
  }

  static void writeNotification(JsonWriter &writer, const NotificationActionDescription &description) {
    constexpr std::array levels{"info", "success", "warning", "failure"};
    writer.object([&](JsonWriter &object) {
      object.member("title", description.title.view());
      object.member("message", description.message.view());
      object.member("level", std::string_view{levels[static_cast<std::size_t>(description.level)]});
      object.member("duration_ms", description.duration_ms);
      object.member("target", [&](JsonWriter &value) {
        writeTarget(value, description.target);
      });
    });
  }

  static void emptyObject(JsonWriter &writer) {
    writer.object([](JsonWriter &) {
    });
  }

  static void writeTarget(JsonWriter &writer, NotificationTarget target) {
    constexpr std::array targets{"none", "pane", "tab", "workspace"};
    writer.object([&](JsonWriter &object) {
      const auto name = std::string_view{targets[static_cast<std::size_t>(target.kind)]};
      if (target.kind == NotificationTarget::Kind::none) {
        object.member(name, emptyObject);
      } else {
        object.member(name, target.id);
      }
    });
  }

  static void writeExtended(JsonWriter &writer, DefinitionActionDescription description) {
    writeValue(writer, description.kind == DefinitionActionDescription::Kind::panel ? "open_panel" : "pick", description.index);
  }

  static void writeExtended(JsonWriter &writer, PluginActionDescription description) {
    writeValue(writer, "plugin", [&](JsonWriter &value) {
      value.object([&](JsonWriter &object) {
        object.member("plugin", description.plugin);
        object.member("action", description.action);
      });
    });
  }
};

}
