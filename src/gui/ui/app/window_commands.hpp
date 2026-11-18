#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "key_bindings.hpp"
#include "telar_wire/protocol/clients.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/config/configuration_source.hpp"
#include "ui/foundation/input/window_actions.hpp"
#include "ui/foundation/plugins/plugin_runner.hpp"
#include "ui/foundation/store/store.hpp"
#include <QKeyEvent>
#include <QObject>
#include <QPointF>
#include <QQuickItem>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <optional>

#pragma once

#include "tbc/view.hpp"

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  class ActivitySelection;
  class AttachmentsController;
  class ComponentsController;
  class CopyController;
  class Dialogs;
  class ElementSlots;
  class HistoryController;
  class LinksController;
  class MachineProfilesSource;
  class MachinesCoordinator;
  class NotificationsController;
  class PaletteController;
  class PromptController;
  class TerminalController;
  class WindowDisplay;
  class WindowStatus;
  class WorkspaceFormController;

  // What running a command needs from the window, which only the window can do.
  class CommandsHost {
  public:
    CommandsHost(const CommandsHost&) = delete;
    CommandsHost& operator=(const CommandsHost&) = delete;
    CommandsHost(CommandsHost&&) = delete;
    CommandsHost& operator=(CommandsHost&&) = delete;

    // A command changed the session outside an interaction: every projection catches up.
    virtual void refresh() = 0;
    // The detach command: the window closes and its runtime keeps running.
    virtual void closeWindow() = 0;

  protected:
    CommandsHost() = default;
    ~CommandsHost() = default;
  };

  // Runs what the user asks of the window: the actions QML sends, the key bindings and what
  // their Lua callbacks return, the palette's choices, the effects of a plugin and the commands
  // a client sends through the runtime.
  //
  // A command acts on the active session, or on the dialogs, the machines and the controllers it
  // holds. It knows no part of the window beyond them; the window implements CommandsHost.
  class WindowCommands final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(WindowCommands)
    QML_UNCREATABLE("Use the window's commands")

  public:
    using Dialog = Store::Dialog;

    struct Parts {
      Store& store;
      ConfigurationSource& configuration;
      KeyBindings& keys;
      Dialogs& dialogs;
      MachinesCoordinator& machines;
      MachineProfilesSource& machine_profiles;
      ActivitySelection& activity_selection;
      WindowDisplay& display;
      WindowStatus& status;
      PaletteController& palette;
      HistoryController& history;
      WorkspaceFormController& workspace_form;
      CopyController& copy;
      PromptController& prompt;
      TerminalController& terminals;
      ComponentsController& components;
      AttachmentsController& attachments;
      PluginRunner& plugins;
      NotificationsController& notifications;
      LinksController& links;
      ElementSlots& element_slots;
      CommandsHost& host;
    };

    explicit WindowCommands(const Parts& parts, QObject* parent = nullptr);
    ~WindowCommands() override = default;
    WindowCommands(const WindowCommands&) = delete;
    WindowCommands& operator=(const WindowCommands&) = delete;
    WindowCommands(WindowCommands&&) = delete;
    WindowCommands& operator=(WindowCommands&&) = delete;

    // Answers the commands of the active machine's client. A configuration reply views the
    // commands' buffers, region `a`, until the client encodes it.
    struct HostCommands final : application::ClientCommandHandler {
      HostCommands(tbc::view<WindowCommands&, tbc::lt::a> owner, bool is_active) noexcept
          : commands(owner),
            active(is_active) {}

      void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const override;

      tbc::view<WindowCommands&, tbc::lt::a> commands;
      bool active = false;
    };

    Q_INVOKABLE void execute(telar::gui::qt::window_actions::Action action, const QString& target = {});
    Q_INVOKABLE void submitDialog(const QVariantMap& input);
    // A click on a mod element: runs its action, URL or Lua function.
    Q_INVOKABLE void activateElement(const QString& slot, const QString& key, const QString& revision, int element);
    Q_INVOKABLE void peekActivity(const QString& identity);
    Q_INVOKABLE void editMachineResult(const QVariantMap& choice, telar::gui::qt::window_actions::MachineEditAction action);

    // The commands the palette lists, each with the key that runs it.
    [[nodiscard]] QVariantList list() const;
    // Runs an action outside an interaction of its own: the caller is inside one.
    void perform(window_actions::Action action, const QString& target = {});
    bool handleKey(QKeyEvent& event, QQuickItem& recipient, bool captures = false);
    void interrupt();
    // Runs a binding's action. `resolved` describes actions a Lua render or callback returned;
    // configured bindings need none.
    bool runBinding(BindingAction action, const ConfigurationSource::Actions* resolved = nullptr);
    // Runs the action a mod's component was pressed for; a panel it opens anchors at `anchor`.
    void runComponentBinding(const BindingAction& action, const ConfigurationSource::Actions& actions, QPointF anchor);
    void applyPluginEffects(const application::plugins::PluginEffects& effects);
    // A mutation of the session failed: the open history shows it, or the window's status.
    void fail(const std::exception& error);

    // Runs a user's mutation of the session, then commits it to the store, whose interacted()
    // publishes what the mutation wrote and refreshes the window.
    template <std::invocable Mutation>
    void interact(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        fail(error);
      });
    }

  signals:
    // A command has something to tell the user that no dialog shows.
    void notified(const QString& message);

  private:
    [[nodiscard]] BindingContext context() const;
    void executeBinding(BindingAction action, const ConfigurationSource::Actions* resolved = nullptr);
    void luaBindingFinished(KeyBindings::Hold hold, bool stale, const QString& error, const std::function<void()>& apply);
    void applyEffects(const application::components::ResolvedEffects<ApplicationAllocator>& effects);
    void executeNamedAction(const NamedActionDescription& named);
    void executeCommandTab(BindingAction action, const ConfigurationSource::Actions* resolved);
    void executeNotificationBinding(BindingAction action, const ConfigurationSource::Actions* resolved);
    void openComponentPick(std::size_t index);
    void applyExpression(const InputExpression& expression);
    void scrollBinding(application::ScrollDirection direction);
    [[nodiscard]] QString bindingShortcut(BindingActionKind action) const;
    bool executeNavigation(window_actions::Action action, const QString& target);
    bool executePane(window_actions::Action action, std::uint64_t identity);
    void executeWindowAction(window_actions::Action action);
    bool executeMachineAction(window_actions::Action action);
    void cancelCurrentInteraction();
    [[nodiscard]] static bool answerConfiguration(tbc::view<WindowCommands&, tbc::lt::a> commands, const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply);
    void executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply);

    Store& store_;
    ConfigurationSource& configuration_source_;
    KeyBindings& key_bindings_;
    Dialogs& dialogs_;
    MachinesCoordinator& machines_;
    MachineProfilesSource& machine_profiles_;
    ActivitySelection& activity_selection_;
    WindowDisplay& display_;
    WindowStatus& status_;
    PaletteController& palette_;
    HistoryController& history_;
    WorkspaceFormController& workspace_form_;
    CopyController& copy_;
    PromptController& prompt_;
    TerminalController& terminals_;
    ComponentsController& components_;
    AttachmentsController& attachments_;
    PluginRunner& plugins_;
    NotificationsController& notifications_;
    LinksController& links_;
    ElementSlots& element_slots_;
    CommandsHost& host_;
    // Where the pressed component action that is running was pressed, for a panel it opens.
    ds::Option<QPointF> component_action_anchor_;
  };

}
