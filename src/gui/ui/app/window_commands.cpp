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
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/screen.hpp"
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
#include "ui/foundation/config/configuration_source.hpp"
#include "ui/foundation/links/links_controller.hpp"
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
#include "ui/foundation/models/projection.hpp"
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

import telar.gui.application.workspace_replica;
import telar.gui.components.configuration;
import telar.gui.input.copy_pointer;
import telar.gui.input.key_encoder;

import telar.gui.config.gui_query;
import telar.gui.presentation.notification_center;
import telar.config.client;
import telar.gui.application.session;
import telar.gui.application.workspace_replica;
import telar.gui.components.configuration;
import telar.gui.config.gui_query;
import telar.gui.config.plugin_effects;
import telar.gui.links.cell_links;
import telar.gui.machines.picker;
import telar.gui.machines.profile_store;
import telar.gui.palette.navigation_label;
import telar.gui.presentation.notification_center;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  namespace {

    auto parseLocation(const QString& key) -> WorkspaceLocation {
      return {
          .kind = key.startsWith(QLatin1StringView("worktree:")) ? WorkspaceLocation::Kind::worktree : WorkspaceLocation::Kind::workspace,
          .id = key.section(QLatin1Char(':'), 1).toULongLong(),
      };
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
      default:
        return PaneDirection::down;
      }
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
      default:
        return Dialog::none;
      }
    }

    std::optional<window_actions::Action> nativeAction(BindingActionKind kind) noexcept {
      using Native = window_actions::Action;
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

      const auto* const found = std::ranges::find(actions, kind, &decltype(actions)::value_type::first);

      return found == actions.end() ? std::nullopt : std::optional{found->second};
    }

    std::optional<PaneDirection> navigationDirection(BindingActionKind kind) noexcept {
      constexpr auto directions = std::to_array<std::pair<BindingActionKind, PaneDirection>>({
          {BindingActionKind::navigate_left, PaneDirection::left},
          {BindingActionKind::navigate_right, PaneDirection::right},
          {BindingActionKind::navigate_up, PaneDirection::up},
          {BindingActionKind::navigate_down, PaneDirection::down},
      });

      const auto* const found = std::ranges::find(directions, kind, &decltype(directions)::value_type::first);

      return found == directions.end() ? std::nullopt : std::optional{found->second};
    }

    bool supported(BindingActionKind kind) noexcept {
      return nativeAction(kind).has_value() || navigationDirection(kind).has_value() || kind == BindingActionKind::select_tab || kind == BindingActionKind::select_workspace || kind == BindingActionKind::select_tab_offset || kind == BindingActionKind::scroll_pane_up || kind == BindingActionKind::scroll_pane_down || kind == BindingActionKind::resize_sidebar_left || kind == BindingActionKind::resize_sidebar_right || kind == BindingActionKind::command_tab || kind == BindingActionKind::close_panel || kind == BindingActionKind::refresh_panel;
    }

    bool supported(const ConfigurationSource& configuration, BindingAction action, const ConfigurationSource::Actions* resolved) {
      if (action.kind == BindingActionKind::extended) {
        const auto definition = configuration.definitionAction(action, resolved);

        return configuration.notificationAction(action, resolved).has_value() || configuration.pluginAction(action, resolved).has_value() || definition.has_value();
      }

      return supported(action.kind);
    }

  }

  WindowCommands::WindowCommands(const Parts& parts, QObject* parent)
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

    commands.reserve(static_cast<qsizetype>(palette_actions.size()));
    for (const auto& entry : palette_actions) {
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

  QString WindowCommands::bindingShortcut(BindingActionKind action) const {
    const auto key = key_bindings_.prefixedKeyForAction({.kind = action});
    if (!key) {
      return {};
    }

    const auto style = platform::usesCommandKey() ? KeyLabelStyle::mac : KeyLabelStyle::pc;
    const auto label = KeyLabel::chord(configuration_source_.input().prefix, *key, style);

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

  bool WindowCommands::runBinding(BindingAction action, const ConfigurationSource::Actions* resolved) {
    try {
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
  }

  void WindowCommands::applyEffects(const ResolvedEffects<ApplicationAllocator>& effects) {
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
  void WindowCommands::luaBindingFinished(KeyBindings::Hold hold, bool stale, const QString& error, const std::function<void()>& apply) {
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
      store_.session().navigateDirection(*direction);
      return;
    }

    switch (action.kind) {
    case BindingActionKind::select_tab:
      store_.session().selectTabIndex(static_cast<std::size_t>(action.parameter));
      break;
    case BindingActionKind::select_tab_offset:
      store_.session().selectTabOffset(action.parameter);
      break;
    case BindingActionKind::select_workspace:
      store_.session().selectWorkspaceIndex(static_cast<std::size_t>(action.parameter));
      break;
    case BindingActionKind::scroll_pane_up:
    case BindingActionKind::scroll_pane_down:
      scrollBinding(action.kind == BindingActionKind::scroll_pane_up ? ScrollDirection::up : ScrollDirection::down);
      break;
    case BindingActionKind::resize_sidebar_left:
    case BindingActionKind::resize_sidebar_right: {
      constexpr float resize_columns = 2;
      const auto change = resize_columns * display_.cell().width * (action.kind == BindingActionKind::resize_sidebar_left ? -1.0F : 1.0F);

      display_.setSidebarWidth(display_.sidebarWidth() + change);
    } break;
    case BindingActionKind::command_tab:
      executeCommandTab(action, resolved);
      break;
    case BindingActionKind::close_panel:
      components_.closePanel();
      break;
    case BindingActionKind::refresh_panel:
      components_.refreshPanel();
      break;
    case BindingActionKind::extended:
      if (const auto named = configuration_source_.namedAction(action, resolved)) {
        executeNamedAction(*named);
      } else {
        executeNotificationBinding(action, resolved);
      }

      break;
    default:
      throw std::runtime_error{"Binding action is not yet available in the C++ GUI"};
    }
  }

  void WindowCommands::executeNamedAction(const NamedActionDescription& named) {
    if (const auto* definition = std::get_if<DefinitionActionDescription>(&named)) {
      if (definition->kind == DefinitionActionDescription::Kind::panel) {
        components_.togglePanel(definition->index, component_action_anchor_.value_or(QPointF{-1, -1}));
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

    notifications_.publish({.level = notification->level, .target = notification->target, .title = notification->title.view(), .message = notification->message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification->duration_ms) * NotificationInput::nanoseconds_per_millisecond});
  }

  void WindowCommands::executeCommandTab(BindingAction action, const ConfigurationSource::Actions* resolved) {
    const auto command = configuration_source_.commandTab(action, resolved);
    if (!command) {
      emit notified(QStringLiteral("That command tab expired"));
    } else if (store_.session().createCommandTab(*command) == TabCreationOutcome::busy) {
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
      store_.session().paste(pane->id, expression.paste.view());
      prompt_.publishWrite();
    } else {
      for (const auto key : std::span{expression.keys}.first(expression.length)) {
        key_bindings_.synthetic(key, pane->id, pane->screen.modes());
      }
    }
  }

  void WindowCommands::scrollBinding(ScrollDirection direction) {
    store_.session().scrollFocused(direction);
    if (const auto* pane = store_.session().focusedPane()) {
      emit terminals_.terminalChanged(pane->id);
    }
  }

  void WindowCommands::HostCommands::operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const {
    if (!active) {
      UnsupportedClientCommand{}(message, reply);
    } else if (!answerConfiguration(commands, message, reply)) {
      commands.executeHostCommand(message, reply);
    }
  }

  void WindowCommands::peekActivity(const QString& identity) {
    interact([&] {
      activity_selection_.select(identity, true);
    });
  }

  bool WindowCommands::answerConfiguration(tbc::view<WindowCommands&, tbc::lt::a> commands, const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) {
    switch (message.action) {
    case ClientAction::config_show: {
      // The query rewrites the source's buffer, so the state views a copy of the title, not the session.
      const auto title = commands.store_.session().configuration().window_title;
      auto state = commands.store_.session().clientViewState();

      state.window_title = title.view();
      reply.text = commands.configuration_source_.query(ConfigurationQuery::parse(message.text, message.value), state);

      return true;
    }
    case ClientAction::plugin_list:
    case ClientAction::plugin_get: {
      const auto page = commands.configuration_source_.queryPlugins(message);

      reply.text = page.text;
      reply.value = page.next;

      return true;
    }
    default:
      return false;
    }
  }

  void WindowCommands::executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    switch (message.action) {
    case ClientAction::plugin_enable:
    case ClientAction::plugin_disable:
      configuration_source_.setPluginEnabled(message, message.action == ClientAction::plugin_enable);
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::plugin_run:
      plugins_.start(configuration_source_.pluginInvocation(message, context()));
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::config_reload:
      configuration_source_.requestReload();
      reply.status = ClientCommandStatus::admitted;
      break;
    // Name prompts: none opens over copy mode or another prompt, and
    // copy mode does not start over a prompt.
    case ClientAction::client_open_goto:
      if (copy_.active() || store_.dialog().kind != Dialog::none) {
        throw EncodingError{"ClientPromptUnavailable"};
      }

      executeWindowAction(window_actions::Action::goto_picker);
      break;
    case ClientAction::client_open_history:
      if (copy_.active() || store_.dialog().kind != Dialog::none) {
        throw EncodingError{"ClientPromptUnavailable"};
      }

      executeWindowAction(window_actions::Action::history);
      reply.status = ClientCommandStatus::admitted;
      break;
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

      break;
    case ClientAction::client_open_link: {
      const auto target = LinkTarget::fromUri(message.text);
      if (!target) {
        throw EncodingError{"InvalidLink"};
      }

      const auto* focused = store_.session().focusedPane();
      if (!links_.open(*target, focused == nullptr ? std::nullopt : std::optional{focused->id})) {
        throw EncodingError{"LinkOpeningUnavailable"};
      }

      reply.text = {};
      reply.status = ClientCommandStatus::admitted;
      break;
    }
    default:
      UnsupportedClientCommand{}(message, reply);
      break;
    }
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
        store_.session().renameTab(text);
      } else if (store_.dialog().kind == Dialog::rename_workspace) {
        store_.session().renameWorkspace(text);
      } else if (store_.dialog().kind == Dialog::copy_search) {
        store_.session().searchCopy(text);
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

  bool WindowCommands::executeNavigation(window_actions::Action action, const QString& target) {
    const auto identity = target.toULongLong();

    if (action == window_actions::Action::new_tab) {
      store_.session().createTab();
    } else if (action == window_actions::Action::select_tab) {
      if (const auto* active = store_.session().activeTab()) {
        store_.session().selectTab({.workspace = active->location.workspace, .tab_id = identity});
      }
    } else if (action == window_actions::Action::select_tab_index) {
      store_.session().selectTabIndex(static_cast<std::size_t>(identity));
    } else if (action == window_actions::Action::next_tab || action == window_actions::Action::previous_tab) {
      store_.session().selectTabOffset(action == window_actions::Action::next_tab ? 1 : -1);
    } else if (action == window_actions::Action::move_tab_next || action == window_actions::Action::move_tab_previous) {
      store_.session().moveTab(action == window_actions::Action::move_tab_next ? TabMoveDirection::next : TabMoveDirection::previous);
    } else if (action == window_actions::Action::close_tab) {
      if (const auto* active = store_.session().activeTab()) {
        store_.session().closeTab({.workspace = active->location.workspace, .tab_id = identity == 0 ? active->location.tab_id : identity});
      }
    } else if (action == window_actions::Action::select_workspace) {
      store_.session().selectWorkspace(parseLocation(target));
    } else if (action == window_actions::Action::leave_worktree) {
      store_.session().leaveWorktree();
    } else if (action == window_actions::Action::forget_gone_worktrees) {
      store_.session().forgetGoneWorktrees();
    } else if (action == window_actions::Action::select_agent) {
      activity_selection_.select(target);
    } else {
      return false;
    }

    return true;
  }

  bool WindowCommands::executePane(window_actions::Action action, std::uint64_t identity) {
    if (action == window_actions::Action::focus_left || action == window_actions::Action::focus_right || action == window_actions::Action::focus_up || action == window_actions::Action::focus_down) {
      store_.session().focusDirection(paneDirection(action));
    } else if (action == window_actions::Action::resize_left || action == window_actions::Action::resize_right || action == window_actions::Action::resize_up || action == window_actions::Action::resize_down) {
      store_.session().resizeDirection(paneDirection(action));
    } else if (action == window_actions::Action::focus_pane) {
      store_.session().focusPane(identity);
    } else if (action == window_actions::Action::split_horizontal) {
      store_.session().split(ClientLayoutAxis::horizontal);
    } else if (action == window_actions::Action::split_vertical) {
      store_.session().split(ClientLayoutAxis::vertical);
    } else if (action == window_actions::Action::close_pane) {
      if (const auto* pane = store_.session().focusedPane()) {
        store_.session().closePane(identity == 0 ? pane->id : identity);
      }
    } else if (action == window_actions::Action::fullscreen) {
      store_.session().toggleFullscreen();
    } else {
      return false;
    }

    return true;
  }

  void WindowCommands::executeWindowAction(window_actions::Action action) {
    if (executeMachineAction(action)) {
      return;
    }

    if (action == window_actions::Action::detach) {
      host_.closeWindow();
    } else if (action == window_actions::Action::toggle_sidebar) {
      store_.session().setSidebarVisible(!store_.session().configuration().sidebar_visible);
      display_.publish();
    } else if (action == window_actions::Action::toggle_workspace_list) {
      store_.session().setWorkspaceListCollapsed(!store_.session().workspaceListCollapsed());
      display_.publish();
    } else if (action == window_actions::Action::history) {
      dialogs_.show(Dialog::history);
      history_.open();
    } else if (action == window_actions::Action::palette || action == window_actions::Action::goto_picker) {
      dialogs_.showPalette(action == window_actions::Action::palette ? PaletteMode::actions : PaletteMode::navigate);
    } else if (action == window_actions::Action::path_picker) {
      dialogs_.showPaths();
    } else if (action == window_actions::Action::suggest_command) {
      dialogs_.showPalette(PaletteMode::suggest);
    } else if (action == window_actions::Action::new_workspace || action == window_actions::Action::rename_tab || action == window_actions::Action::rename_workspace) {
      dialogs_.show(dialogFor(action));
    } else if (action == window_actions::Action::copy_mode) {
      if (store_.dialog().kind == Dialog::none && store_.session().enterBlocks()) {
        prompt_.publish(store_.session().changedPane());
        emit terminals_.terminalChanged(store_.session().changedPane());
      } else if (store_.dialog().kind == Dialog::none) {
        static_cast<void>(store_.session().enterCopyMode());
        status_.publish();
        if (const auto& copy = store_.session().copyMode().state()) {
          emit terminals_.terminalChanged(copy->pane_id);
        }
      }
    } else if (action == window_actions::Action::cancel) {
      cancelCurrentInteraction();
    }
  }

  void WindowCommands::cancelCurrentInteraction() {
    store_.session().invalidateSuggestion();
    if (palette_.restoreParent()) {
      return;
    }

    const auto& copy = store_.session().copyMode().state();
    if (store_.dialog().kind == Dialog::none && copy && !copy->pointer) {
      const auto pane_id = copy->pane_id;

      store_.session().leaveCopyMode();
      emit terminals_.terminalChanged(pane_id);
      status_.publish();
    }

    dialogs_.show(Dialog::none);
  }

  bool WindowCommands::executeMachineAction(window_actions::Action action) {
    switch (action) {
    case window_actions::Action::machine_picker:
      dialogs_.showPalette(PaletteMode::machines);
      break;
    case window_actions::Action::next_machine:
      machines_.move(1);
      break;
    case window_actions::Action::previous_machine:
      machines_.move(-1);
      break;
    case window_actions::Action::add_machine:
      dialogs_.showMachinePrompt();
      break;
    default:
      return false;
    }

    return true;
  }

  void WindowCommands::editMachineResult(const QVariantMap& choice, window_actions::MachineEditAction action) {
    const auto target = palette_.chosenMachine(choice);
    if (!target || !target->machine || !store_.machines().contains(*target->machine) || target->machine->slot == Machines::local_slot) {
      return;
    }

    const auto token = *target->machine;

    interact([&] {
      if (action == window_actions::MachineEditAction::rename) {
        dialogs_.showMachinePrompt(token);
      } else {
        const auto label = store_.machines().row(token.slot).label.view();

        static_cast<void>(machine_profiles_.edit({.kind = MachineEditKind::remove, .label = label, .value = {}}));
      }
    });
  }

  void WindowCommands::applyPluginEffects(const PluginEffects& effects) {
    for (const auto& effect : effects.effects()) {
      if (const auto* action = std::get_if<BindingAction>(&effect)) {
        executeBinding(*action);
        if (action->kind == BindingActionKind::detach) {
          break;
        }
      } else {
        const auto& notification = std::get<NotificationActionDescription>(effect);

        notifications_.publish({.level = notification.level, .target = notification.target, .title = notification.title.view(), .message = notification.message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification.duration_ms) * NotificationInput::nanoseconds_per_millisecond});
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

  void WindowCommands::activateElement(const QString& slot, const QString& key, const QString& revision, int element) {
    const auto* instance = element_slots_.find(slot, key);
    if (instance == nullptr || !instance->rendered || QString::number(instance->revision) != revision || element < 0 || static_cast<std::size_t>(element) >= instance->rendered->elements.size()) {
      return;
    }

    // Hold the content: a render may replace the instance while the click runs.
    const auto rendered = instance->rendered;
    const auto& node = rendered->elements[static_cast<std::size_t>(element)];

    try {
      if (node.callback != components::Element::none) {
        const auto hold = key_bindings_.hold();

        configuration_source_.invokeElement(instance->id, node.callback, components_.context(), instance->item, [this, hold](LuaOutcome<ConfigurationSource::Effects> outcome) {
          luaBindingFinished(hold, outcome.stale, outcome.error, [&] {
            applyEffects(**outcome.value);
          });

          // The function may have changed state any slot reads.
          element_slots_.invalidate();
        });
      } else if (node.action != components::Element::none && node.action < rendered->bindings.size()) {
        static_cast<void>(runBinding(rendered->bindings[node.action], &rendered->actions));
      } else if (const auto url = rendered->view(node.url); !url.empty()) {
        if (const auto target = LinkTarget::fromUri(url)) {
          static_cast<void>(links_.open(*target));
        }
      }
    } catch (const std::exception& error) {
      status_.fail(error);
    }
  }

}
