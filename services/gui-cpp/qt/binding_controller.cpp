#include "application.hpp"
#include "application/notification_item.hpp"
#include "application/records.hpp"
#include "components/configuration.hpp"
#include "config/action_descriptions.hpp"
#include "config/callback.hpp"
#include "configuration_source.hpp"
#include "input/action.hpp"
#include "input/binding.hpp"
#include "input/key_event.hpp"
#include "input/key_label.hpp"
#include "key_bindings.hpp"
#include "native_form_field.hpp"
#include "palette_actions.hpp"
#include "platform/window.hpp"
#include "projection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <QString>
#include <QStringLiteral>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qcoreevent.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qevent.h>
#include <QtQuick/qquickitem.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <variant>

namespace telar::gui::qt {

namespace {

std::optional<Application::Action> nativeAction(BindingActionKind kind) noexcept {
  using Native = Application::Action;
  using Binding = BindingActionKind;
  constexpr auto actions = std::to_array<std::pair<Binding, Native>>({
      {Binding::new_tab, Native::new_tab},
      {Binding::next_tab, Native::next_tab},
      {Binding::previous_tab, Native::previous_tab},
      {Binding::move_tab_next, Native::move_tab_next},
      {Binding::move_tab_previous, Native::move_tab_previous},
      {Binding::rename_tab, Native::rename_tab},
      {Binding::close_tab, Native::close_tab},
      {Binding::new_workspace, Native::new_workspace},
      {Binding::rename_workspace, Native::rename_workspace},
      {Binding::focus_left, Native::focus_left},
      {Binding::focus_right, Native::focus_right},
      {Binding::focus_up, Native::focus_up},
      {Binding::focus_down, Native::focus_down},
      {Binding::resize_left, Native::resize_left},
      {Binding::resize_right, Native::resize_right},
      {Binding::resize_up, Native::resize_up},
      {Binding::resize_down, Native::resize_down},
      {Binding::split_horizontal, Native::split_horizontal},
      {Binding::split_vertical, Native::split_vertical},
      {Binding::close_pane, Native::close_pane},
      {Binding::toggle_pane_fullscreen, Native::fullscreen},
      {Binding::toggle_sidebar, Native::toggle_sidebar},
      {Binding::toggle_workspace_list, Native::toggle_workspace_list},
      {Binding::history_palette, Native::history},
      {Binding::palette, Native::palette},
      {Binding::goto_picker, Native::goto_picker},
      {Binding::path_picker, Native::path_picker},
      {Binding::suggest_command, Native::suggest_command},
      {Binding::leave_worktree, Native::leave_worktree},
      {Binding::forget_gone_worktrees, Native::forget_gone_worktrees},
      {Binding::detach, Native::detach},
      {Binding::copy_mode, Native::copy_mode},
      {Binding::machine_picker, Native::machine_picker},
      {Binding::next_machine, Native::next_machine},
      {Binding::previous_machine, Native::previous_machine},
      {Binding::add_machine, Native::add_machine},
  });
  const auto *const found = std::ranges::find(actions, kind, &decltype(actions)::value_type::first);

  return found == actions.end() ? std::nullopt : std::optional{found->second};
}

std::optional<PaneDirection> navigationDirection(BindingActionKind kind) noexcept {
  constexpr auto directions = std::to_array<std::pair<BindingActionKind, PaneDirection>>({
      {BindingActionKind::navigate_left, PaneDirection::left},
      {BindingActionKind::navigate_right, PaneDirection::right},
      {BindingActionKind::navigate_up, PaneDirection::up},
      {BindingActionKind::navigate_down, PaneDirection::down},
  });
  const auto *const found = std::ranges::find(directions, kind, &decltype(directions)::value_type::first);

  return found == directions.end() ? std::nullopt : std::optional{found->second};
}

bool supported(BindingActionKind kind) noexcept {
  return nativeAction(kind).has_value() || navigationDirection(kind).has_value() || kind == BindingActionKind::select_tab || kind == BindingActionKind::select_workspace || kind == BindingActionKind::select_tab_offset || kind == BindingActionKind::scroll_pane_up || kind == BindingActionKind::scroll_pane_down || kind == BindingActionKind::resize_sidebar_left || kind == BindingActionKind::resize_sidebar_right || kind == BindingActionKind::command_tab || kind == BindingActionKind::close_panel || kind == BindingActionKind::refresh_panel;
}

bool supported(const ConfigurationSource &configuration, BindingAction action) {
  if (action.kind == BindingActionKind::extended) {
    const auto definition = configuration.definitionAction(action);

    return configuration.notificationAction(action).has_value() || configuration.pluginAction(action).has_value() || definition.has_value();
  }

  return supported(action.kind);
}

}

QVariantList Application::commands() const {
  QVariantList commands;
  commands.reserve(static_cast<qsizetype>(palette_actions.size()));
  for (const auto &entry : palette_actions) {
    const auto action = nativeAction(entry.action);
    if (!action) {
      continue;
    }

    commands.append(QVariantMap{
        {QStringLiteral("action"), QVariant::fromValue(*action)},
        {QStringLiteral("label"), toQString(entry.label)},
        {QStringLiteral("shortcut"), bindingShortcut(entry.action)},
    });
  }

  return commands;
}

QString Application::bindingShortcut(BindingActionKind action) const {
  const auto key = key_bindings_.prefixedKeyForAction({.kind = action});
  if (!key) {
    return {};
  }

  const auto style = platform::usesCommandKey() ? KeyLabelStyle::mac : KeyLabelStyle::pc;
  const auto label = KeyLabel::chord(configuration_source_.input().prefix, *key, style);

  return toQString(label.view());
}

BindingContext Application::bindingContext() const {
  BindingContext context{.sidebar_visible = session().configuration().sidebar_visible};
  const auto *active = session().activeTab();
  if (active == nullptr) {
    return context;
  }

  context.focused_pane_id = active->focused_pane;
  context.active_tab_index = active->position;
  context.pane_count = static_cast<std::uint16_t>(std::ranges::count_if(active->layout.nodes(), [](const auto &node) {
    return std::holds_alternative<ClientLayoutPane>(node);
  }));
  context.tab_count = static_cast<std::uint16_t>(std::ranges::count_if(session().tabs(), [&](const auto &tab) {
    return sameWorkspace(tab->location.workspace, active->location.workspace);
  }));

  return context;
}

std::optional<BindingRepeat> Application::bindingRepeat(BindingAction action) const {
  if (!dialog_.isEmpty() || pick_controller_.isOpen() || (action.kind != BindingActionKind::scroll_pane_up && action.kind != BindingActionKind::scroll_pane_down)) {
    return {};
  }

  const auto *pane = session().focusedPane();
  if (pane == nullptr || !pane->attached || pane->exited) {
    return {};
  }

  constexpr std::chrono::milliseconds interval{100};

  return BindingRepeat{.interval_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(interval).count()), .owner = pane->id};
}

bool Application::handleBindingKey(QKeyEvent &event, QQuickItem &recipient, bool captures) {
  if (interceptAttachmentKey(event)) {
    return true;
  }

  const bool dismiss = event.type() == QEvent::KeyPress && !event.isAutoRepeat() && event.key() == Qt::Key_Escape && event.modifiers() == Qt::NoModifier;
  if (pick_controller_.isOpen()) {
    if (dismiss) {
      auto *field = qobject_cast<NativeFormField *>(&recipient);
      if (field != nullptr && field->cancelComposition()) {
        return true;
      }

      closeComponentPick();

      return true;
    }

    return false;
  }

  if (component_surfaces_.open_panel && dismiss) {
    closeComponentPanel();

    return true;
  }

  return key_bindings_.route(event, recipient, captures);
}

void Application::interruptBindings() {
  key_bindings_.interrupt();
}

bool Application::runBinding(BindingAction action, std::optional<DefinitionActionDescription> definition) {
  try {
    if (definition) {
      const auto *components = configuration_source_.components();
      if (action.kind != BindingActionKind::extended || action.generation != configuration_source_.configurationGeneration() || components == nullptr || !components->contains(action)) {
        throw std::invalid_argument{"Validated component action expired"};
      }
    }

    if (action.kind == BindingActionKind::expression) {
      applyExpression(configuration_source_.expression(action, bindingContext()));
    } else if (action.kind == BindingActionKind::callback) {
      const auto effects = configuration_source_.invoke(action, bindingContext());
      const auto actions = std::span{effects.actions}.first(effects.length);
      if (std::ranges::any_of(actions, [&](const auto &effect) {
            return !supported(configuration_source_, effect);
          })) {
        throw std::runtime_error{"Callback returned an action not yet available in the C++ GUI"};
      }

      for (const auto effect : actions) {
        executeBinding(effect);
      }
    } else {
      executeBinding(action, definition);
    }

    refresh();

    return true;
  } catch (const std::exception &error) {
    fail(error);

    return false;
  }
}

void Application::executeBinding(BindingAction action, std::optional<DefinitionActionDescription> definition) {
  pending_activity_.reset();
  if (action.kind != BindingActionKind::copy_mode) {
    leaveKeyboardCopyMode();
  }

  if (const auto native = nativeAction(action.kind)) {
    if (!executeNavigation(*native, {}) && !executePane(*native, 0)) {
      executeWindowAction(*native);
    }

    return;
  }

  if (const auto direction = navigationDirection(action.kind)) {
    session().navigateDirection(*direction);
    return;
  }

  switch (action.kind) {
  case BindingActionKind::select_tab:
    session().selectTabIndex(static_cast<std::size_t>(action.parameter));
    break;
  case BindingActionKind::select_tab_offset:
    session().selectTabOffset(action.parameter);
    break;
  case BindingActionKind::select_workspace:
    session().selectWorkspaceIndex(static_cast<std::size_t>(action.parameter));
    break;
  case BindingActionKind::scroll_pane_up:
  case BindingActionKind::scroll_pane_down:
    scrollBinding(action.kind == BindingActionKind::scroll_pane_up ? ScrollDirection::up : ScrollDirection::down);
    break;
  case BindingActionKind::resize_sidebar_left:
  case BindingActionKind::resize_sidebar_right: {
    constexpr float resize_columns = 2;
    const auto change = resize_columns * cell_metrics_.width * (action.kind == BindingActionKind::resize_sidebar_left ? -1.0F : 1.0F);
    setSidebarWidth(sidebarWidth() + change);
  } break;
  case BindingActionKind::command_tab:
    executeCommandTab(action);
    break;
  case BindingActionKind::close_panel:
    closeComponentPanel();
    break;
  case BindingActionKind::refresh_panel:
    refreshComponentPanel();
    break;
  case BindingActionKind::extended:
    if (const auto resolved = definition ? definition : configuration_source_.definitionAction(action)) {
      if (resolved->kind == DefinitionActionDescription::Kind::panel) {
        toggleComponentPanel(resolved->index);
      } else {
        openComponentPick(resolved->index);
      }
    } else if (const auto plugin = configuration_source_.pluginAction(action)) {
      startPlugin(configuration_source_.pluginInvocation(*plugin, bindingContext()));
    } else {
      executeNotificationBinding(action);
    }
    break;
  default:
    throw std::runtime_error{"Binding action is not yet available in the C++ GUI"};
  }
}

void Application::executeNotificationBinding(BindingAction action) {
  const auto notification = configuration_source_.notificationAction(action);
  if (!notification) {
    throw std::runtime_error{"Binding action is not yet available in the C++ GUI"};
  }

  publishNotification({.level = notification->level, .target = notification->target, .title = notification->title.view(), .message = notification->message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification->duration_ms) * NotificationInput::nanoseconds_per_millisecond});
}

void Application::executeCommandTab(BindingAction action) {
  const auto command = configuration_source_.commandTab(action);
  if (!command) {
    emit notification(QStringLiteral("That command tab expired"));
  } else if (session().createCommandTab(*command) == TabCreationOutcome::busy) {
    emit notification(QStringLiteral("tabs.one_operation_in_flight: limit 1 tab operation reached"));
  }
}

void Application::applyExpression(const InputExpression &expression) {
  if (expression.kind == InputExpression::Kind::consume) {
    return;
  }

  const auto *pane = session().focusedPane();
  if (pane == nullptr || !pane->attached || pane->exited) {
    throw std::runtime_error{"No terminal is ready for expression input"};
  }

  if (expression.kind == InputExpression::Kind::paste) {
    session().paste(pane->id, expression.paste.view());
  } else {
    for (const auto key : std::span{expression.keys}.first(expression.length)) {
      key_bindings_.synthetic(key, pane->id, pane->screen.modes());
    }
  }
}

void Application::scrollBinding(ScrollDirection direction) {
  session().scrollFocused(direction);
  if (const auto *pane = session().focusedPane()) {
    emit terminalChanged(pane->id);
  }
}

}
