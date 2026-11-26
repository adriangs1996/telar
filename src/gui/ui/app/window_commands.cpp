#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "window_commands.hpp"
#include "activity_selection.hpp"
#include "dialogs.hpp"
#include "key_bindings.hpp"
#include "machines_coordinator.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "ui/app/chrome/components/components_controller.hpp"
#include "ui/app/overlays/machine_prompt/machine_profiles_source.hpp"
#include "ui/app/overlays/notifications/notifications_controller.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"
#include "ui/app/overlays/workspace_form/workspace_form_controller.hpp"
#include "ui/app/panes/attachments/attachments_controller.hpp"
#include "ui/app/panes/terminal/copy_controller.hpp"
#include "ui/app/panes/terminal/history/history_controller.hpp"
#include "ui/app/panes/terminal/prompt/prompt_controller.hpp"
#include "ui/app/panes/terminal/terminal_controller.hpp"
#include "ui/design/controls/native_form_field.hpp"
#include "ui/design/elements/element_slots.hpp"
#include "ui/kit/config/configuration_source.hpp"
#include "ui/kit/links/links_controller.hpp"
#include "window_display.hpp"
#include "window_status.hpp"
#include <QScopeGuard>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <initializer_list>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <variant>

#include "platform/window.hpp"
#include "ui/kit/models/projection.hpp"
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

import telar.gui.application;

import telar.config.client;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    auto parseLocation(const QString& key) -> WorkspaceLocation {
      return {
          .kind = key.startsWith(QLatin1StringView("worktree:")) ? WorkspaceLocation::Kind::worktree : WorkspaceLocation::Kind::workspace,
          .id = key.section(QLatin1Char(':'), 1).toULongLong(),
      };
    }

    // The action of the key that moves the focus that way.
    constexpr window_actions::Action focusAction(PaneDirection direction) noexcept {
      switch (direction) {
      case PaneDirection::left:
        return window_actions::Action::focus_left;
      case PaneDirection::right:
        return window_actions::Action::focus_right;
      case PaneDirection::up:
        return window_actions::Action::focus_up;
      case PaneDirection::down:
        return window_actions::Action::focus_down;
      }

      return window_actions::Action::none;
    }

    auto paneDirection(window_actions::Action action) noexcept -> PaneDirection {
      switch (action) {
      case window_actions::Action::focus_left:
      case window_actions::Action::resize_left:
        return PaneDirection::left;
      case window_actions::Action::focus_right:
      case window_actions::Action::resize_right:
        return PaneDirection::right;
      case window_actions::Action::focus_up:
      case window_actions::Action::resize_up:
        return PaneDirection::up;
      case window_actions::Action::none:
      case window_actions::Action::new_tab:
      case window_actions::Action::new_editor:
      case window_actions::Action::new_editor_tab:
      case window_actions::Action::editor_files:
      case window_actions::Action::editor_grep:
      case window_actions::Action::editor_buffers:
      case window_actions::Action::select_tab:
      case window_actions::Action::select_tab_index:
      case window_actions::Action::next_tab:
      case window_actions::Action::previous_tab:
      case window_actions::Action::move_tab_next:
      case window_actions::Action::move_tab_previous:
      case window_actions::Action::focus_down:
      case window_actions::Action::resize_down:
      case window_actions::Action::detach:
      case window_actions::Action::close_tab:
      case window_actions::Action::select_workspace:
      case window_actions::Action::focus_pane:
      case window_actions::Action::select_agent:
      case window_actions::Action::split_horizontal:
      case window_actions::Action::split_vertical:
      case window_actions::Action::close_pane:
      case window_actions::Action::fullscreen:
      case window_actions::Action::toggle_sidebar:
      case window_actions::Action::toggle_workspace_list:
      case window_actions::Action::history:
      case window_actions::Action::palette:
      case window_actions::Action::goto_picker:
      case window_actions::Action::leave_worktree:
      case window_actions::Action::forget_gone_worktrees:
      case window_actions::Action::new_workspace:
      case window_actions::Action::rename_tab:
      case window_actions::Action::rename_workspace:
      case window_actions::Action::cancel:
      case window_actions::Action::copy_mode:
      case window_actions::Action::path_picker:
      case window_actions::Action::suggest_command:
      case window_actions::Action::machine_picker:
      case window_actions::Action::next_machine:
      case window_actions::Action::previous_machine:
      case window_actions::Action::add_machine:
      case window_actions::Action::explorer:
      case window_actions::Action::monitor:
      case window_actions::Action::process_picker:
      case window_actions::Action::process_terminate:
      case window_actions::Action::process_kill:
      case window_actions::Action::process_stop:
      case window_actions::Action::process_continue:
      case window_actions::Action::process_lower_priority:
      case window_actions::Action::process_copy_command:
      case window_actions::Action::process_focus_pane:
      case window_actions::Action::process_review_stack:
      case window_actions::Action::process_review_files:
      case window_actions::Action::process_review_logs:
      case window_actions::Action::theme_picker:
        return PaneDirection::down;
      }

      // An action outside the enum points down.
      return PaneDirection::down;
    }

    auto dialogFor(window_actions::Action action) -> Store::Dialog {
      using Dialog = Store::Dialog;

      switch (action) {
      case window_actions::Action::palette:
        return Dialog::palette;
      case window_actions::Action::new_workspace:
        return Dialog::new_workspace;
      case window_actions::Action::rename_tab:
        return Dialog::rename_tab;
      case window_actions::Action::rename_workspace:
        return Dialog::rename_workspace;
      case window_actions::Action::none:
      case window_actions::Action::new_tab:
      case window_actions::Action::new_editor:
      case window_actions::Action::new_editor_tab:
      case window_actions::Action::editor_files:
      case window_actions::Action::editor_grep:
      case window_actions::Action::editor_buffers:
      case window_actions::Action::select_tab:
      case window_actions::Action::select_tab_index:
      case window_actions::Action::next_tab:
      case window_actions::Action::previous_tab:
      case window_actions::Action::move_tab_next:
      case window_actions::Action::move_tab_previous:
      case window_actions::Action::focus_left:
      case window_actions::Action::focus_right:
      case window_actions::Action::focus_up:
      case window_actions::Action::focus_down:
      case window_actions::Action::resize_left:
      case window_actions::Action::resize_right:
      case window_actions::Action::resize_up:
      case window_actions::Action::resize_down:
      case window_actions::Action::detach:
      case window_actions::Action::close_tab:
      case window_actions::Action::select_workspace:
      case window_actions::Action::focus_pane:
      case window_actions::Action::select_agent:
      case window_actions::Action::split_horizontal:
      case window_actions::Action::split_vertical:
      case window_actions::Action::close_pane:
      case window_actions::Action::fullscreen:
      case window_actions::Action::toggle_sidebar:
      case window_actions::Action::toggle_workspace_list:
      case window_actions::Action::history:
      case window_actions::Action::goto_picker:
      case window_actions::Action::leave_worktree:
      case window_actions::Action::forget_gone_worktrees:
      case window_actions::Action::cancel:
      case window_actions::Action::copy_mode:
      case window_actions::Action::path_picker:
      case window_actions::Action::suggest_command:
      case window_actions::Action::machine_picker:
      case window_actions::Action::next_machine:
      case window_actions::Action::previous_machine:
      case window_actions::Action::add_machine:
      case window_actions::Action::explorer:
      case window_actions::Action::monitor:
      case window_actions::Action::process_picker:
      case window_actions::Action::process_terminate:
      case window_actions::Action::process_kill:
      case window_actions::Action::process_stop:
      case window_actions::Action::process_continue:
      case window_actions::Action::process_lower_priority:
      case window_actions::Action::process_copy_command:
      case window_actions::Action::process_focus_pane:
      case window_actions::Action::process_review_stack:
      case window_actions::Action::process_review_files:
      case window_actions::Action::process_review_logs:
      case window_actions::Action::theme_picker:
        return Dialog::none;
      }

      // An action outside the enum opens no dialog.
      return Dialog::none;
    }

    ds::Option<window_actions::Action> nativeAction(BindingActionKind kind) noexcept {
      using Native = window_actions::Action;
      using Binding = BindingActionKind;
      constexpr auto actions = ds::Array<std::pair<Binding, Native>, 55>{
          {
              {Binding::new_tab, Native::new_tab},
              {Binding::new_editor, Native::new_editor},
              {Binding::new_editor_tab, Native::new_editor_tab},
              {Binding::editor_files, Native::editor_files},
              {Binding::editor_grep, Native::editor_grep},
              {Binding::editor_buffers, Native::editor_buffers},
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
              {Binding::explorer, Native::explorer},
              {Binding::monitor, Native::monitor},
              {Binding::process_picker, Native::process_picker},
              {Binding::process_terminate, Native::process_terminate},
              {Binding::process_kill, Native::process_kill},
              {Binding::process_stop, Native::process_stop},
              {Binding::process_continue, Native::process_continue},
              {Binding::process_lower_priority, Native::process_lower_priority},
              {Binding::process_copy_command, Native::process_copy_command},
              {Binding::process_focus_pane, Native::process_focus_pane},
              {Binding::process_review_stack, Native::process_review_stack},
              {Binding::process_review_files, Native::process_review_files},
              {Binding::process_review_logs, Native::process_review_logs},
              {Binding::theme_picker, Native::theme_picker},
          },
      };

      const auto* const found = std::ranges::find(actions, kind, &decltype(actions)::value_type::first);

      return found == actions.end() ? ds::none : ds::Option{found->second};
    }

    ds::Option<PaneDirection> navigationDirection(BindingActionKind kind) noexcept {
      constexpr auto directions = ds::Array<std::pair<BindingActionKind, PaneDirection>, 4>{
          {
              {BindingActionKind::navigate_left, PaneDirection::left},
              {BindingActionKind::navigate_right, PaneDirection::right},
              {BindingActionKind::navigate_up, PaneDirection::up},
              {BindingActionKind::navigate_down, PaneDirection::down},
          },
      };

      const auto* const found = std::ranges::find(directions, kind, &decltype(directions)::value_type::first);

      return found == directions.end() ? ds::none : ds::Option{found->second};
    }

    bool supported(BindingActionKind kind) noexcept {
      return nativeAction(kind).hasValue() || navigationDirection(kind).hasValue() || kind == BindingActionKind::select_tab || kind == BindingActionKind::select_workspace || kind == BindingActionKind::select_tab_offset || kind == BindingActionKind::scroll_pane_up || kind == BindingActionKind::scroll_pane_down || kind == BindingActionKind::resize_sidebar_left || kind == BindingActionKind::resize_sidebar_right || kind == BindingActionKind::command_tab || kind == BindingActionKind::close_panel || kind == BindingActionKind::refresh_panel;
    }

    bool supported(const ConfigurationSource& configuration, BindingAction action, const ConfigurationSource::Actions* resolved) {
      if (action.kind == BindingActionKind::extended) {
        const auto definition = configuration.definitionAction(action, resolved);

        return configuration.notificationAction(action, resolved).hasValue() || configuration.pluginAction(action, resolved).hasValue() || definition.hasValue();
      }

      return supported(action.kind);
    }

  }

  WindowCommands::WindowCommands(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent)
      : QObject(parent),
        store_(parts.store),
        configuration_source_(parts.configuration),
        key_bindings_(parts.keys),
        dialogs_(parts.dialogs),
        machines_(parts.machines),
        machine_profiles_(parts.machine_profiles),
        activity_selection_(parts.activity_selection),
        display_(parts.display),
        status_(parts.status),
        palette_(parts.palette),
        history_(parts.history),
        workspace_form_(parts.workspace_form),
        copy_(parts.copy),
        prompt_(parts.prompt),
        terminals_(parts.terminals),
        components_(parts.components),
        attachments_(parts.attachments),
        plugins_(parts.plugins),
        notifications_(parts.notifications),
        links_(parts.links),
        element_slots_(parts.element_slots),
        host_(parts.host) {}

  void WindowCommands::perform(window_actions::Action action, const QString& target) {
    if (!executeNavigation(action, target) && !executePane(action, target.toULongLong())) {
      executeWindowAction(action);
    }
  }

  void WindowCommands::runComponentBinding(const BindingAction& action, const ConfigurationSource::Actions& actions, QPointF anchor) {
    const auto previous = std::exchange(component_action_anchor_, anchor);
    const auto restore = qScopeGuard([&] {
      component_action_anchor_ = previous;
    });

    static_cast<void>(runBinding(action, &actions));
  }

  QVariantList WindowCommands::list() const {
    QVariantList commands;

    commands.reserve(static_cast<qsizetype>(application::palette::palette_actions.size()));
    for (const auto& entry : application::palette::palette_actions) {
      const auto action = nativeAction(entry.action);
      if (!action) {
        continue;
      }

      commands.append(QVariantMap{
          {QStringLiteral("action"), QVariant::fromValue(*action)},
          {QStringLiteral("label"), toQString(entry.label)},
          {QStringLiteral("shortcut"), bindingShortcut(entry.action)},
          {QStringLiteral("destructive"), entry.destructive},
      });
    }

    return commands;
  }

  QString WindowCommands::bindingShortcut(BindingActionKind action) const {
    const auto key = key_bindings_.prefixedKeyForAction({.kind = action});
    if (!key) {
      return {};
    }

    const auto style = platform::usesCommandKey() ? application::bindings::KeyLabelStyle::mac : application::bindings::KeyLabelStyle::pc;
    const auto label = application::bindings::KeyLabel::chord(configuration_source_.input().prefix, *key, style);

    return toQString(label.view());
  }

  BindingContext WindowCommands::context() const {
    return sessionBindingContext(store_.session());
  }

  bool WindowCommands::handleKey(QKeyEvent& event, QQuickItem& recipient, bool captures) {
    if (attachments_.interceptKey(event)) {
      return true;
    }

    const bool dismiss = event.type() == QEvent::KeyPress && !event.isAutoRepeat() && event.key() == Qt::Key_Escape && event.modifiers() == Qt::NoModifier;

    if (components_.pickOpen()) {
      if (dismiss) {
        auto* field = qobject_cast<NativeFormField*>(&recipient);
        if (field != nullptr && field->cancelComposition()) {
          return true;
        }

        components_.closePick();

        return true;
      }

      return false;
    }

    if (components_.panelOpen() && dismiss) {
      components_.closePanel();

      return true;
    }

    return key_bindings_.route(event, recipient, captures);
  }

  void WindowCommands::interrupt() {
    key_bindings_.interrupt();
  }

  bool WindowCommands::runBinding(BindingAction action, const ConfigurationSource::Actions* resolved) try {
    const bool configured = action.kind == BindingActionKind::extended || action.kind == BindingActionKind::command_tab;
    if (resolved != nullptr && ((configured && action.generation != configuration_source_.configurationGeneration()) || !resolved->contains(action) || !components_.actionsLive(*resolved))) {
      throw std::invalid_argument{"Validated component action expired"};
    }

    if (action.kind == BindingActionKind::expression) {
      const auto hold = key_bindings_.hold();

      configuration_source_.expression(action, context(), [this, hold](LuaOutcome<InputExpression> outcome) {
        luaBindingFinished(hold, outcome.stale, outcome.error, [&] {
          applyExpression(*outcome.value);
        });
      });
    } else if (action.kind == BindingActionKind::callback) {
      const auto hold = key_bindings_.hold();

      configuration_source_.invoke(action, context(), [this, hold](LuaOutcome<ConfigurationSource::Effects> outcome) {
        luaBindingFinished(hold, outcome.stale, outcome.error, [&] {
          applyEffects(**outcome.value);
        });
      });
    } else {
      executeBinding(action, resolved);
      host_.refresh();
    }

    return true;
  } catch (const std::exception& error) {
    status_.fail(error);

    return false;
  }

  void WindowCommands::applyEffects(const application::components::ResolvedEffects<ApplicationAllocator>& effects) {
    const auto actions = std::span{effects.effects.actions}.first(effects.effects.length);
    if (std::ranges::any_of(actions, [&](const auto& effect) {
          return !supported(configuration_source_, effect, &effects.actions);
        })) {
      throw std::runtime_error{"Callback returned an action not yet available in the C++ GUI"};
    }

    for (const auto effect : actions) {
      executeBinding(effect, &effects.actions);
    }
  }

  // Releases keys typed while the Lua thread ran the binding, after applying its result.
  void WindowCommands::luaBindingFinished(KeyBindings::Hold hold, bool stale, const QString& error, ds::Function<void()> apply) {
    try {
      if (!stale) {
        if (!error.isEmpty()) {
          throw std::runtime_error{error.toStdString()};
        }

        apply();
        host_.refresh();
      }
    } catch (const std::exception& failure) {
      status_.fail(failure);
    }

    key_bindings_.release(hold);
  }

  void WindowCommands::executeBinding(BindingAction action, const ConfigurationSource::Actions* resolved) {
    activity_selection_.cancel();
    if (action.kind != BindingActionKind::copy_mode) {
      copy_.leaveKeyboard();
    }

    if (const auto native = nativeAction(action.kind)) {
      if (!executeNavigation(*native, {}) && !executePane(*native, 0)) {
        executeWindowAction(*native);
      }

      return;
    }

    if (const auto direction = navigationDirection(action.kind)) {
      if (!insideTakes(focusAction(*direction))) {
        application::workbench::navigate(store_.sessionMut(), *direction);
      }

      return;
    }

    executeWindowBinding(action, resolved);
  }

  // An action a configuration defines: one it names, or a notification it shows.
  void WindowCommands::executeExtendedBinding(BindingAction action, const ConfigurationSource::Actions* resolved) {
    if (const auto named = configuration_source_.namedAction(action, resolved)) {
      executeNamedAction(*named);
    } else {
      executeNotificationBinding(action, resolved);
    }
  }

  void WindowCommands::executeWindowBinding(BindingAction action, const ConfigurationSource::Actions* resolved) { // NOLINT(readability-function-size): one case per kind, in one switch, is what makes a kind without its case an error
    switch (action.kind) {
    case BindingActionKind::select_tab:
      application::workbench::selectTabAt(store_.sessionMut(), static_cast<std::size_t>(action.parameter));
      return;
    case BindingActionKind::select_tab_offset:
      application::workbench::selectTabBeside(store_.sessionMut(), action.parameter);
      return;
    case BindingActionKind::select_workspace:
      application::workbench::selectWorkspaceAt(store_.sessionMut(), static_cast<std::size_t>(action.parameter));
      return;
    case BindingActionKind::scroll_pane_up:
    case BindingActionKind::scroll_pane_down:
      scrollBinding(action.kind == BindingActionKind::scroll_pane_up ? application::ScrollDirection::up : application::ScrollDirection::down);
      return;
    case BindingActionKind::resize_sidebar_left:
    case BindingActionKind::resize_sidebar_right: {
      constexpr float resize_columns = 2;
      const auto change = resize_columns * display_.cell().width * (action.kind == BindingActionKind::resize_sidebar_left ? -1.0F : 1.0F);

      display_.setSidebarWidth(display_.sidebarWidth() + static_cast<qreal>(change));
      return;
    }
    case BindingActionKind::command_tab:
      executeCommandTab(action, resolved);
      return;
    case BindingActionKind::close_panel:
      components_.closePanel();
      return;
    case BindingActionKind::refresh_panel:
      components_.refreshPanel();
      return;
    case BindingActionKind::extended:
      executeExtendedBinding(action, resolved);
      return;
    case BindingActionKind::none:
    case BindingActionKind::split_horizontal:
    case BindingActionKind::split_vertical:
    case BindingActionKind::focus_left:
    case BindingActionKind::focus_right:
    case BindingActionKind::focus_up:
    case BindingActionKind::focus_down:
    case BindingActionKind::navigate_left:
    case BindingActionKind::navigate_right:
    case BindingActionKind::navigate_up:
    case BindingActionKind::navigate_down:
    case BindingActionKind::resize_left:
    case BindingActionKind::resize_right:
    case BindingActionKind::resize_up:
    case BindingActionKind::resize_down:
    case BindingActionKind::toggle_pane_fullscreen:
    case BindingActionKind::toggle_sidebar:
    case BindingActionKind::toggle_workspace_list:
    case BindingActionKind::leave_worktree:
    case BindingActionKind::forget_gone_worktrees:
    case BindingActionKind::new_workspace:
    case BindingActionKind::rename_workspace:
    case BindingActionKind::close_pane:
    case BindingActionKind::new_tab:
    case BindingActionKind::new_editor:
    case BindingActionKind::new_editor_tab:
    case BindingActionKind::editor_files:
    case BindingActionKind::editor_grep:
    case BindingActionKind::editor_buffers:
    case BindingActionKind::next_tab:
    case BindingActionKind::previous_tab:
    case BindingActionKind::rename_tab:
    case BindingActionKind::close_tab:
    case BindingActionKind::move_tab_previous:
    case BindingActionKind::move_tab_next:
    case BindingActionKind::detach:
    case BindingActionKind::copy_mode:
    case BindingActionKind::goto_picker:
    case BindingActionKind::history_palette:
    case BindingActionKind::path_picker:
    case BindingActionKind::suggest_command:
    case BindingActionKind::next_machine:
    case BindingActionKind::previous_machine:
    case BindingActionKind::machine_picker:
    case BindingActionKind::add_machine:
    case BindingActionKind::explorer:
    case BindingActionKind::monitor:
    case BindingActionKind::process_picker:
    case BindingActionKind::process_terminate:
    case BindingActionKind::process_kill:
    case BindingActionKind::process_stop:
    case BindingActionKind::process_continue:
    case BindingActionKind::process_lower_priority:
    case BindingActionKind::process_copy_command:
    case BindingActionKind::process_focus_pane:
    case BindingActionKind::process_review_stack:
    case BindingActionKind::process_review_files:
    case BindingActionKind::process_review_logs:
    case BindingActionKind::theme_picker:
    case BindingActionKind::palette:
    case BindingActionKind::callback:
    case BindingActionKind::expression:
      throw std::runtime_error{"Binding action is not yet available in the C++ GUI"};
    }

    // A binding outside the enum is unsupported.
    throw std::runtime_error{"Binding action is not yet available in the C++ GUI"};
  }

  void WindowCommands::executeNamedAction(const NamedActionDescription& named) {
    if (const auto* definition = std::get_if<DefinitionActionDescription>(&named)) {
      if (definition->kind == DefinitionActionDescription::Kind::panel) {
        components_.togglePanel(definition->index, component_action_anchor_.valueOr(QPointF{-1, -1}));
      } else {
        openComponentPick(definition->index);
      }
    } else {
      plugins_.start(configuration_source_.pluginInvocation(std::get<PluginActionDescription>(named), context()));
    }
  }

  void WindowCommands::executeNotificationBinding(BindingAction action, const ConfigurationSource::Actions* resolved) {
    const auto notification = configuration_source_.notificationAction(action, resolved);
    if (!notification) {
      throw std::runtime_error{"Binding action is not yet available in the C++ GUI"};
    }

    notifications_.publish({.level = notification->level, .target = notification->target, .title = notification->title.view(), .message = notification->message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification->duration_ms) * application::notifications::NotificationInput::nanoseconds_per_millisecond});
  }

  void WindowCommands::executeCommandTab(BindingAction action, const ConfigurationSource::Actions* resolved) {
    const auto command = configuration_source_.commandTab(action, resolved);
    if (!command) {
      emit notified(QStringLiteral("That command tab expired"));
    } else if (application::nvim::editCommand(store_.sessionMut(), command->argv())) {
      // `telar.action.edit`: the window opened the file itself, without a tab for the command.
      return;
    } else if (application::workbench::createCommandTab(store_.sessionMut(), *command) == application::TabCreationOutcome::busy) {
      emit notified(QStringLiteral("tabs.one_operation_in_flight: limit 1 tab operation reached"));
    }
  }

  void WindowCommands::applyExpression(const InputExpression& expression) {
    if (expression.kind == InputExpression::Kind::consume) {
      return;
    }

    const auto* pane = store_.session().focusedPane();
    if (pane == nullptr || !pane->attached || pane->exited) {
      throw std::runtime_error{"No terminal is ready for expression input"};
    }

    if (expression.kind == InputExpression::Kind::paste) {
      const auto pane_id = pane->id;

      store_.sessionMut().paste(pane_id, expression.paste.view());
      prompt_.publishWrite();
    } else {
      for (const auto key : std::span{expression.keys}.first(expression.length)) {
        key_bindings_.synthetic(key, pane->id, pane->screen.modes());
      }
    }
  }

  void WindowCommands::scrollBinding(application::ScrollDirection direction) {
    application::terminal::input::scroll(store_.sessionMut(), direction);
    if (const auto* pane = store_.session().focusedPane()) {
      emit terminals_.terminalChanged(pane->id);
    }
  }

  void WindowCommands::HostCommands::operator()(const ClientCommand& message, tbc::mut_a<CompleteClientCommand> reply) {
    if (!active) {
      application::UnsupportedClientCommand{}(message, reply);
    } else if (!answerConfiguration(commands, message, reply)) {
      commands.executeHostCommand(message, reply);
    }
  }

  void WindowCommands::peekActivity(const QString& identity) {
    interact([&] {
      activity_selection_.select(identity, true);
    });
  }

  bool WindowCommands::answerConfiguration(tbc::mut_a<WindowCommands> commands, const ClientCommand& message, tbc::mut_a<CompleteClientCommand> reply) {
    switch (message.action) {
    case ClientAction::config_show: {
      // The query rewrites the source's buffer, so the state views a copy of the title, not the session.
      const auto title = commands.store_.session().configuration.window_title;
      auto state = commands.store_.session().clientViewState();

      state.window_title = title.view();
      reply.text = commands.configuration_source_.query(application::configuration::ConfigurationQuery::parse(message.text, message.value), state);

      return true;
    }
    case ClientAction::plugin_list:
    case ClientAction::plugin_get: {
      const auto page = commands.configuration_source_.queryPlugins(message);

      reply.text = page.text;
      reply.value = page.next;

      return true;
    }
    case ClientAction::workspace_select:
    case ClientAction::tab_create:
    case ClientAction::tab_select:
    case ClientAction::tab_next:
    case ClientAction::tab_previous:
    case ClientAction::pane_create:
    case ClientAction::pane_split:
    case ClientAction::pane_close:
    case ClientAction::pane_focus:
    case ClientAction::pane_resize:
    case ClientAction::pane_fullscreen:
    case ClientAction::pane_scroll:
    case ClientAction::sidebar_get:
    case ClientAction::sidebar_show:
    case ClientAction::sidebar_hide:
    case ClientAction::sidebar_resize:
    case ClientAction::workspace_list_expand:
    case ClientAction::workspace_list_collapse:
    case ClientAction::client_open_goto:
    case ClientAction::client_open_history:
    case ClientAction::client_copy_mode:
    case ClientAction::notification_dismiss:
    case ClientAction::client_open_link:
    case ClientAction::client_clipboard_copy:
    case ClientAction::pane_copy:
    case ClientAction::layout_get:
    case ClientAction::layout_apply:
    case ClientAction::config_reload:
    case ClientAction::plugin_enable:
    case ClientAction::plugin_disable:
    case ClientAction::plugin_run:
    case ClientAction::editor_open:
      return false;
    }

    // A host action outside the enum is not a configuration query.
    return false;
  }

  void WindowCommands::executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    switch (message.action) {
    case ClientAction::plugin_enable:
    case ClientAction::plugin_disable:
      configuration_source_.setPluginEnabled(message, message.action == ClientAction::plugin_enable);
      reply.status = ClientCommandStatus::admitted;
      return;
    case ClientAction::plugin_run:
      plugins_.start(configuration_source_.pluginInvocation(message, context()));
      reply.status = ClientCommandStatus::admitted;
      return;
    case ClientAction::config_reload:
      configuration_source_.requestReload();
      reply.status = ClientCommandStatus::admitted;
      return;
    // Name prompts: none opens over copy mode or another prompt, and
    // copy mode does not start over a prompt.
    case ClientAction::client_open_goto:
      if (copy_.active() || store_.dialog().kind != Dialog::none) {
        throw EncodingError{"ClientPromptUnavailable"};
      }

      executeWindowAction(window_actions::Action::goto_picker);
      return;
    case ClientAction::client_open_history:
      if (copy_.active() || store_.dialog().kind != Dialog::none) {
        throw EncodingError{"ClientPromptUnavailable"};
      }

      executeWindowAction(window_actions::Action::history);
      reply.status = ClientCommandStatus::admitted;
      return;
    case ClientAction::client_copy_mode:
      if (!copy_.active()) {
        if (store_.dialog().kind != Dialog::none) {
          throw EncodingError{"CopyModeUnavailable"};
        }

        executeWindowAction(window_actions::Action::copy_mode);
        if (!copy_.active()) {
          throw EncodingError{"CopyModeUnavailable"};
        }
      }

      return;
    case ClientAction::client_open_link: {
      const auto target = application::terminal::links::LinkTarget::fromUri(message.text);
      if (!target) {
        throw EncodingError{"InvalidLink"};
      }

      const auto* focused = store_.session().focusedPane();
      if (!links_.open(*target, focused == nullptr ? ds::none : ds::Option{focused->id})) {
        throw EncodingError{"LinkOpeningUnavailable"};
      }

      reply.text = {};
      reply.status = ClientCommandStatus::admitted;
      return;
    }
    case ClientAction::workspace_select:
    case ClientAction::tab_create:
    case ClientAction::tab_select:
    case ClientAction::tab_next:
    case ClientAction::tab_previous:
    case ClientAction::pane_create:
    case ClientAction::pane_split:
    case ClientAction::pane_close:
    case ClientAction::pane_focus:
    case ClientAction::pane_resize:
    case ClientAction::pane_fullscreen:
    case ClientAction::pane_scroll:
    case ClientAction::sidebar_get:
    case ClientAction::sidebar_show:
    case ClientAction::sidebar_hide:
    case ClientAction::sidebar_resize:
    case ClientAction::workspace_list_expand:
    case ClientAction::workspace_list_collapse:
    case ClientAction::notification_dismiss:
    case ClientAction::client_clipboard_copy:
    case ClientAction::pane_copy:
    case ClientAction::layout_get:
    case ClientAction::layout_apply:
    case ClientAction::config_show:
    case ClientAction::plugin_list:
    case ClientAction::plugin_get:
    case ClientAction::editor_open:
      application::UnsupportedClientCommand{}(message, reply);
      return;
    }

    // A host action outside the enum is unsupported.
    application::UnsupportedClientCommand{}(message, reply);
  }

  void WindowCommands::execute(window_actions::Action action, const QString& target) {
    key_bindings_.cancelSequence();
    interact([&] {
      if (action != window_actions::Action::copy_mode && (action != window_actions::Action::cancel || store_.dialog().kind == Dialog::none)) {
        copy_.leaveKeyboard();
      }

      if (!executeNavigation(action, target) && !executePane(action, target.toULongLong())) {
        executeWindowAction(action);
      }
    });
  }

  void WindowCommands::submitDialog(const QVariantMap& input) {
    interact([&] {
      const auto name = input.value(QStringLiteral("text")).toString().toUtf8();
      const auto path = input.value(QStringLiteral("path")).toString().toUtf8();
      const std::string_view text{name.constData(), static_cast<std::size_t>(name.size())};

      if (store_.dialog().kind == Dialog::new_workspace) {
        if (!workspace_form_.submit(input)) {
          return;
        }
      } else if (store_.dialog().kind == Dialog::rename_tab) {
        application::workbench::renameTab(store_.sessionMut(), text);
      } else if (store_.dialog().kind == Dialog::rename_workspace) {
        application::workbench::renameWorkspace(store_.sessionMut(), text);
      } else if (store_.dialog().kind == Dialog::copy_search) {
        application::terminal::copy_mode::search(store_.sessionMut(), text);
      }

      dialogs_.show(Dialog::none);
    });
  }

  void WindowCommands::fail(const std::exception& error) {
    if (store_.dialog().kind == Dialog::history) {
      history_.fail(error);
    } else {
      status_.fail(error);
    }
  }

  namespace {

    // What an action opens the editor's picker on; nothing for the other actions.
    ds::Option<application::nvim::NvimPickSource> pickerSource(window_actions::Action action) noexcept {
      using Source = application::nvim::NvimPickSource;

      if (action == window_actions::Action::editor_files) {
        return Source::files;
      }

      if (action == window_actions::Action::editor_grep) {
        return Source::text;
      }

      return action == window_actions::Action::editor_buffers ? ds::Option<Source>{Source::buffers} : ds::none;
    }

  }

  // An editor beside the focused pane, or in a tab of its own; or the picker of the tab's.
  bool WindowCommands::executeEditor(window_actions::Action action) {
    if (action == window_actions::Action::new_editor) {
      static_cast<void>(application::workbench::splitEditor(store_.sessionMut(), ClientLayoutAxis::horizontal));
      return true;
    }

    if (action == window_actions::Action::new_editor_tab) {
      static_cast<void>(application::workbench::createEditorTab(store_.sessionMut()));
      return true;
    }

    // The picker of the tab's editor pane, which takes the focus.
    if (const auto source = pickerSource(action)) {
      if (!application::nvim::find(store_.sessionMut(), *source)) {
        status_.report(QStringLiteral("This tab has no editor pane"));
      }

      return true;
    }

    return false;
  }

  bool WindowCommands::executeNavigation(window_actions::Action action, const QString& target) {
    if (executeEditor(action)) {
      return true;
    }

    const auto identity = target.toULongLong();

    if (action == window_actions::Action::new_tab) {
      application::workbench::createTab(store_.sessionMut());
    } else if (action == window_actions::Action::select_tab) {
      if (const auto* active = store_.session().activeTab()) {
        // The tab is read before the session lends itself to change.
        const TabLocation tab{.workspace = active->location.workspace, .tab_id = identity};

        application::workbench::selectTab(store_.sessionMut(), tab);
      }
    } else if (action == window_actions::Action::select_tab_index) {
      application::workbench::selectTabAt(store_.sessionMut(), static_cast<std::size_t>(identity));
    } else if (action == window_actions::Action::next_tab || action == window_actions::Action::previous_tab) {
      application::workbench::selectTabBeside(store_.sessionMut(), action == window_actions::Action::next_tab ? 1 : -1);
    } else if (action == window_actions::Action::move_tab_next || action == window_actions::Action::move_tab_previous) {
      application::workbench::moveTab(store_.sessionMut(), action == window_actions::Action::move_tab_next ? TabMoveDirection::next : TabMoveDirection::previous);
    } else if (action == window_actions::Action::close_tab) {
      if (const auto* active = store_.session().activeTab()) {
        const TabLocation tab{.workspace = active->location.workspace, .tab_id = identity == 0 ? active->location.tab_id : identity};

        application::workbench::closeTab(store_.sessionMut(), tab);
      }
    } else if (action == window_actions::Action::select_workspace) {
      application::workbench::selectWorkspace(store_.sessionMut(), parseLocation(target));
    } else if (action == window_actions::Action::leave_worktree) {
      application::workbench::leaveWorktree(store_.sessionMut());
    } else if (action == window_actions::Action::forget_gone_worktrees) {
      application::workbench::forgetGoneWorktrees(store_.sessionMut());
    } else if (action == window_actions::Action::select_agent) {
      activity_selection_.select(target);
    } else {
      return false;
    }

    return true;
  }

  void WindowCommands::setInside(tbc::val_a<ds::Function<bool(window_actions::Action)>> inside) {
    inside_ = std::move(inside);
  }

  bool WindowCommands::insideTakes(window_actions::Action action) {
    return inside_(action);
  }

  bool WindowCommands::executePane(window_actions::Action action, std::uint64_t identity) {
    if (action == window_actions::Action::focus_left || action == window_actions::Action::focus_right || action == window_actions::Action::focus_up || action == window_actions::Action::focus_down) {
      if (!insideTakes(action)) {
        application::workbench::focusToward(store_.sessionMut(), paneDirection(action));
      }
    } else if (action == window_actions::Action::resize_left || action == window_actions::Action::resize_right || action == window_actions::Action::resize_up || action == window_actions::Action::resize_down) {
      application::workbench::resizeToward(store_.sessionMut(), paneDirection(action));
    } else if (action == window_actions::Action::focus_pane) {
      application::workbench::focusPane(store_.sessionMut(), identity);
    } else if (action == window_actions::Action::split_horizontal) {
      application::workbench::split(store_.sessionMut(), ClientLayoutAxis::horizontal);
    } else if (action == window_actions::Action::split_vertical) {
      application::workbench::split(store_.sessionMut(), ClientLayoutAxis::vertical);
    } else if (action == window_actions::Action::close_pane) {
      if (const auto* pane = store_.session().focusedPane()) {
        const auto pane_id = identity == 0 ? pane->id : identity;

        application::workbench::closePane(store_.sessionMut(), pane_id);
      }
    } else if (action == window_actions::Action::fullscreen) {
      application::workbench::toggleFullscreen(store_.sessionMut());
    } else {
      return false;
    }

    return true;
  }

  void WindowCommands::executeWindowAction(window_actions::Action action) {
    if (executeMachineAction(action)) {
      return;
    }

    // The monitor and its process actions belong to the monitor's controller.
    if (action >= window_actions::Action::monitor && action <= window_actions::Action::process_review_logs) {
      emit monitorRequested(action);
      return;
    }

    if (requestOverlay(action)) {
      return;
    }

    if (action == window_actions::Action::detach) {
      host_.closeWindow();
    } else if (action == window_actions::Action::toggle_sidebar) {
      store_.sessionMut().setSidebarVisible(!store_.sessionMut().configuration.sidebar_visible);
      display_.publish();
    } else if (action == window_actions::Action::toggle_workspace_list) {
      store_.sessionMut().setWorkspaceListCollapsed(!store_.sessionMut().workspaceListCollapsed());
      display_.publish();
    } else if (action == window_actions::Action::history) {
      dialogs_.show(Dialog::history);
      history_.open();
    } else if (action == window_actions::Action::palette || action == window_actions::Action::goto_picker) {
      dialogs_.showPalette(action == window_actions::Action::palette ? application::palette::PaletteMode::all : application::palette::PaletteMode::navigate);
    } else if (action == window_actions::Action::path_picker) {
      dialogs_.showPaths();
    } else if (action == window_actions::Action::suggest_command) {
      dialogs_.showPalette(application::palette::PaletteMode::suggest);
    } else if (action == window_actions::Action::new_workspace || action == window_actions::Action::rename_tab || action == window_actions::Action::rename_workspace) {
      dialogs_.show(dialogFor(action));
    } else if (action == window_actions::Action::copy_mode) {
      if (store_.dialog().kind == Dialog::none && store_.sessionMut().enterBlocks()) {
        prompt_.publish(store_.session().changedPane());
        emit terminals_.terminalChanged(store_.session().changedPane());
      } else if (store_.dialog().kind == Dialog::none) {
        static_cast<void>(application::terminal::copy_mode::enter(store_.sessionMut()));
        status_.publish();
        if (const auto& copy = application::terminal::copy_mode::view(store_.session()).state()) {
          emit terminals_.terminalChanged(copy->pane_id);
        }
      }
    } else if (action == window_actions::Action::cancel) {
      cancelCurrentInteraction();
    }
  }

  bool WindowCommands::requestOverlay(window_actions::Action action) {
    // The explorer and the theme picker belong to controllers of their own.
    if (action == window_actions::Action::explorer) {
      emit explorerRequested();
      return true;
    }

    if (action == window_actions::Action::theme_picker) {
      emit themesRequested();
      return true;
    }

    return false;
  }

  void WindowCommands::cancelCurrentInteraction() {
    application::palette::discard(store_.sessionMut());
    if (palette_.restoreParent()) {
      return;
    }

    const auto& copy = application::terminal::copy_mode::view(store_.session()).state();
    if (store_.dialog().kind == Dialog::none && copy && !copy->pointer) {
      const auto pane_id = copy->pane_id;

      application::terminal::copy_mode::leave(store_.sessionMut());
      emit terminals_.terminalChanged(pane_id);
      status_.publish();
    }

    dialogs_.show(Dialog::none);
  }

  bool WindowCommands::executeMachineAction(window_actions::Action action) {
    switch (action) {
    case window_actions::Action::machine_picker:
      dialogs_.showPalette(application::palette::PaletteMode::machines);
      return true;
    case window_actions::Action::next_machine:
      machines_.move(1);
      return true;
    case window_actions::Action::previous_machine:
      machines_.move(-1);
      return true;
    case window_actions::Action::add_machine:
      dialogs_.showMachineWizard();
      return true;
    case window_actions::Action::none:
    case window_actions::Action::new_tab:
    case window_actions::Action::new_editor:
    case window_actions::Action::new_editor_tab:
    case window_actions::Action::editor_files:
    case window_actions::Action::editor_grep:
    case window_actions::Action::editor_buffers:
    case window_actions::Action::select_tab:
    case window_actions::Action::select_tab_index:
    case window_actions::Action::next_tab:
    case window_actions::Action::previous_tab:
    case window_actions::Action::move_tab_next:
    case window_actions::Action::move_tab_previous:
    case window_actions::Action::focus_left:
    case window_actions::Action::focus_right:
    case window_actions::Action::focus_up:
    case window_actions::Action::focus_down:
    case window_actions::Action::resize_left:
    case window_actions::Action::resize_right:
    case window_actions::Action::resize_up:
    case window_actions::Action::resize_down:
    case window_actions::Action::detach:
    case window_actions::Action::close_tab:
    case window_actions::Action::select_workspace:
    case window_actions::Action::focus_pane:
    case window_actions::Action::select_agent:
    case window_actions::Action::split_horizontal:
    case window_actions::Action::split_vertical:
    case window_actions::Action::close_pane:
    case window_actions::Action::fullscreen:
    case window_actions::Action::toggle_sidebar:
    case window_actions::Action::toggle_workspace_list:
    case window_actions::Action::history:
    case window_actions::Action::palette:
    case window_actions::Action::goto_picker:
    case window_actions::Action::leave_worktree:
    case window_actions::Action::forget_gone_worktrees:
    case window_actions::Action::new_workspace:
    case window_actions::Action::rename_tab:
    case window_actions::Action::rename_workspace:
    case window_actions::Action::cancel:
    case window_actions::Action::copy_mode:
    case window_actions::Action::path_picker:
    case window_actions::Action::suggest_command:
    case window_actions::Action::explorer:
    case window_actions::Action::monitor:
    case window_actions::Action::process_picker:
    case window_actions::Action::process_terminate:
    case window_actions::Action::process_kill:
    case window_actions::Action::process_stop:
    case window_actions::Action::process_continue:
    case window_actions::Action::process_lower_priority:
    case window_actions::Action::process_copy_command:
    case window_actions::Action::process_focus_pane:
    case window_actions::Action::process_review_stack:
    case window_actions::Action::process_review_files:
    case window_actions::Action::process_review_logs:
    case window_actions::Action::theme_picker:
      return false;
    }

    // An action outside the enum is not a machine action.
    return false;
  }

  void WindowCommands::editMachineResult(const QVariantMap& choice, window_actions::MachineEditAction action) {
    const auto target = palette_.chosenMachine(choice);
    if (!target || !target->machine || !store_.machines().contains(*target->machine) || target->machine->slot == application::machines::Machines::local_slot) {
      return;
    }

    const auto token = *target->machine;

    interact([&] {
      if (action == window_actions::MachineEditAction::rename) {
        dialogs_.showMachinePrompt(token);
      } else {
        const auto label = store_.machines().row(token.slot).label.view();

        static_cast<void>(machine_profiles_.edit({.kind = application::machines::MachineEditKind::remove, .label = label, .value = {}}));
      }
    });
  }

  void WindowCommands::applyPluginEffects(const application::plugins::PluginEffects& effects) {
    for (const auto& effect : effects.effects()) {
      if (const auto* action = std::get_if<BindingAction>(&effect)) {
        executeBinding(*action);
        if (action->kind == BindingActionKind::detach) {
          break;
        }
      } else {
        const auto& notification = std::get<NotificationActionDescription>(effect);

        notifications_.publish({.level = notification.level, .target = notification.target, .title = notification.title.view(), .message = notification.message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification.duration_ms) * application::notifications::NotificationInput::nanoseconds_per_millisecond});
      }
    }
  }

  void WindowCommands::openComponentPick(std::size_t index) {
    if (attachments_.modalOpen()) {
      return;
    }

    if (store_.dialog().kind != Dialog::none) {
      execute(window_actions::Action::cancel);
    }

    components_.rememberPickFocus();
    interrupt();
    components_.openPick(index);
  }

  void WindowCommands::activateElement(const QString& slot, const QString& key, const QString& revision, int element) try { // NOLINT(bugprone-easily-swappable-parameters): QML invokes it with the elementActivated signal's arguments.
    const auto* instance = element_slots_.find(slot, key);
    if (instance == nullptr || !instance->rendered || QString::number(instance->revision) != revision || element < 0 || static_cast<std::size_t>(element) >= instance->rendered->elements.size()) {
      return;
    }

    // Hold the content: a render may replace the instance while the click runs.
    const auto rendered = instance->rendered;
    const auto& node = rendered->elements[static_cast<std::size_t>(element)];

    if (node.callback != application::components::Element::none) {
      const auto hold = key_bindings_.hold();

      configuration_source_.invokeElement(instance->id, node.callback, components_.context(), instance->item, [this, hold](LuaOutcome<ConfigurationSource::Effects> outcome) {
        luaBindingFinished(hold, outcome.stale, outcome.error, [&] {
          applyEffects(**outcome.value);
        });

        // The function may have changed state any slot reads.
        element_slots_.invalidate();
      });
    } else if (node.action != application::components::Element::none && node.action < rendered->bindings.size()) {
      static_cast<void>(runBinding(rendered->bindings[node.action], &rendered->actions));
    } else if (const auto url = rendered->view(node.url); !url.empty()) {
      if (const auto target = application::terminal::links::LinkTarget::fromUri(url)) {
        static_cast<void>(links_.open(*target));
      }
    }
  } catch (const std::exception& error) {
    status_.fail(error);
  }

}
