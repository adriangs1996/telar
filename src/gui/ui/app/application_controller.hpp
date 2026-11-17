#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "activity_selection.hpp"
#include "application/dependencies.hpp"
#include "application_effects.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "dialogs.hpp"
#include "frame_presenter.hpp"
#include "input/wheel_accumulator.hpp"
#include "key_bindings.hpp"
#include "machine_roster.hpp"
#include "machines_coordinator.hpp"
#include "pointer_dispatcher.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/protocol/clients.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "ui/app/chrome/activity/activity_controller.hpp"
#include "ui/app/chrome/components/components_controller.hpp"
#include "ui/app/chrome/components/machine_chrome/machine_chrome_controller.hpp"
#include "ui/app/chrome/sidebar_controller.hpp"
#include "ui/app/chrome/tabs/tabs_controller.hpp"
#include "ui/app/chrome/workspaces/workspaces_controller.hpp"
#include "ui/app/overlays/link_status/link_status_controller.hpp"
#include "ui/app/overlays/machine_prompt/machine_profiles_source.hpp"
#include "ui/app/overlays/machine_prompt/machine_prompt_controller.hpp"
#include "ui/app/overlays/notifications/notifications_controller.hpp"
#include "ui/app/overlays/notifications/sound_player.hpp"
#include "ui/app/overlays/notifications/system_notifier.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"
#include "ui/app/overlays/peek/peek_controller.hpp"
#include "ui/app/overlays/workspace_form/workspace_form_controller.hpp"
#include "ui/app/panes/attachments/attachments_controller.hpp"
#include "ui/app/panes/documents/documents_controller.hpp"
#include "ui/app/panes/panes_controller.hpp"
#include "ui/app/panes/terminal/copy_controller.hpp"
#include "ui/app/panes/terminal/history/history_controller.hpp"
#include "ui/app/panes/terminal/paths/path_picker_controller.hpp"
#include "ui/app/panes/terminal/prompt/prompt_controller.hpp"
#include "ui/app/panes/terminal/terminal_controller.hpp"
#include "ui/app/panes/terminal/terminal_preparation.hpp"
#include "ui/design/elements/element_slots.hpp"
#include "ui/foundation/config/configuration_source.hpp"
#include "ui/foundation/fonts/font_resolver.hpp"
#include "ui/foundation/input/scroll_event.hpp"
#include "ui/foundation/input/window_actions.hpp"
#include "ui/foundation/links/links_controller.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/machines/machine_client_key.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
#include "ui/foundation/models/list_model.hpp"
#include "ui/foundation/models/machine_activity_target.hpp"
#include "ui/foundation/plugins/plugin_runner.hpp"
#include "ui/foundation/store/store.hpp"
#include "ui/foundation/timing/window_frame_pacer.hpp"
#include "window_display.hpp"
#include "window_status.hpp"
#include <QByteArray>
#include <QColor>
#include <QFutureWatcher>
#include <QHash>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>
#include <QWheelEvent>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <filesystem>
#include <initializer_list>
#include <limits>
#include <lua.h>
#include <optional>
#include <ranges>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>
#include <vector>

#include <functional>

#pragma once

#include "tbc/view.hpp"

#include "application/dependencies.hpp"
#include "core/terminal_size.hpp"
#include "input/wheel_accumulator.hpp"

import telar.gui.components.builtin_content;
import telar.gui.core.metrics;
import telar.gui.presentation.history_pointer;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.prompt.line;
import telar.gui.prompt.editor;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::test {
  struct HistoryPresentation;
  struct FramePacing;
  struct ComponentActions;
  struct MachineWindow;
  struct MachineProfileWindow;
}

namespace telar::gui::qt {

  class TerminalItem;

  // The window and what runs it: the machines and their runtime connections, the store every
  // controller reads, the frames the terminals present, the dialog that is open, and the
  // commands keys, pointers and QML send, which act on the session or the window.
  //
  // Each feature's state lives in its own controller, which reads the store and never calls
  // back here; this controller synchronizes them in order and runs what they ask of the window.
  class ApplicationController final : public QObject, private TerminalHost, private MachinesHost {
    friend struct test::MachineWindow;
    friend struct test::MachineProfileWindow;

    Q_OBJECT
    QML_NAMED_ELEMENT(ApplicationController)
    QML_UNCREATABLE("Use the running GUI controller")
    Q_PROPERTY(telar::gui::qt::AttachmentsController* attachments READ attachments CONSTANT)
    Q_PROPERTY(telar::gui::qt::WindowDisplay* display READ display CONSTANT)
    Q_PROPERTY(telar::gui::qt::WindowStatus* status READ status CONSTANT)
    Q_PROPERTY(telar::gui::qt::Dialogs* dialogs READ dialogs CONSTANT)
    Q_PROPERTY(telar::gui::qt::MachinesCoordinator* machines READ machines CONSTANT)
    Q_PROPERTY(telar::gui::qt::WorkspacesController* workspaces READ workspaces CONSTANT)
    Q_PROPERTY(telar::gui::qt::TabsController* tabs READ tabs CONSTANT)
    Q_PROPERTY(telar::gui::qt::PanesController* panes READ panes CONSTANT)
    Q_PROPERTY(telar::gui::qt::ActivityController* activity READ activity CONSTANT)
    Q_PROPERTY(telar::gui::qt::SidebarController* sidebar READ sidebar CONSTANT)
    Q_PROPERTY(telar::gui::qt::HistoryController* history READ history CONSTANT)
    Q_PROPERTY(int controlModifier READ controlModifier CONSTANT)
    Q_PROPERTY(int superModifier READ superModifier CONSTANT)
    Q_PROPERTY(QVariantMap colors READ colors NOTIFY configurationChanged)
    Q_PROPERTY(QVariantMap font READ font NOTIFY configurationChanged)
    Q_PROPERTY(telar::gui::qt::ComponentsController* components READ components CONSTANT)
    Q_PROPERTY(telar::gui::qt::CopyController* copy READ copy CONSTANT)
    Q_PROPERTY(telar::gui::qt::TerminalController* terminals READ terminals CONSTANT)
    Q_PROPERTY(telar::gui::qt::NotificationsController* notifications READ notifications CONSTANT)
    Q_PROPERTY(QVariantList commands READ commands NOTIFY configurationChanged)
    Q_PROPERTY(telar::gui::qt::MachinePromptController* machinePrompt READ machinePrompt CONSTANT)
    Q_PROPERTY(telar::gui::qt::MachineChromeController* machineChrome READ machineChrome CONSTANT)
    Q_PROPERTY(telar::gui::qt::PeekController* peek READ peek CONSTANT)
    Q_PROPERTY(telar::gui::qt::PromptController* prompt READ prompt CONSTANT)
    Q_PROPERTY(telar::gui::qt::DocumentsController* documents READ documents CONSTANT)
    Q_PROPERTY(telar::gui::qt::LinkStatusController* linkStatus READ linkStatus CONSTANT)
    Q_PROPERTY(telar::gui::qt::PaletteController* palette READ palette CONSTANT)
    Q_PROPERTY(telar::gui::qt::PathPickerController* paths READ paths CONSTANT)
    Q_PROPERTY(telar::gui::qt::WorkspaceFormController* workspaceForm READ workspaceForm CONSTANT)

  public:
    Q_INVOKABLE void editMachineResult(const QVariantMap& choice, telar::gui::qt::window_actions::MachineEditAction action);
    Q_INVOKABLE void peekActivity(const QString& identity);

    using Dialog = Store::Dialog;

    explicit ApplicationController(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~ApplicationController() override;
    ApplicationController(const ApplicationController&) = delete;
    ApplicationController& operator=(const ApplicationController&) = delete;
    ApplicationController(ApplicationController&&) = delete;
    ApplicationController& operator=(ApplicationController&&) = delete;

    [[nodiscard]] AttachmentsController* attachments() noexcept;
    void loadConfiguration(const QString& path, const QString& profile, const QString& theme, const QString& trust_path = {});
    void setWindow(QQuickWindow& window);
    bool eventFilter(QObject* watched, QEvent* event) override;
    [[nodiscard]] Pane<Memory>* pane(std::uint64_t identity) const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] ResolvedFont resolveFont(qreal scale) override;
    void soundPlaybackFinished(std::optional<CommandFailure> failure);

    Q_INVOKABLE void execute(telar::gui::qt::window_actions::Action action, const QString& target = {});
    Q_INVOKABLE void submitDialog(const QVariantMap& input);
    [[nodiscard]] static int controlModifier();
    [[nodiscard]] static int superModifier();

    bool handleBindingKey(QKeyEvent& event, QQuickItem& recipient, bool captures = false);
    void interruptBindings();
    // Runs a binding's action. `resolved` describes actions a Lua render or callback returned;
    // configured bindings need none.
    bool runBinding(BindingAction action, const ConfigurationSource::Actions* resolved = nullptr);

    WorkspacesController* workspaces() noexcept {
      return &workspaces_;
    }

    WindowDisplay* display() noexcept {
      return &display_;
    }

    WindowStatus* status() noexcept {
      return &status_;
    }

    Dialogs* dialogs() noexcept {
      return &dialogs_;
    }

    MachinesCoordinator* machines() noexcept {
      return &machines_;
    }

    MachineRoster* roster() noexcept {
      return &roster_;
    }

    TabsController* tabs() noexcept {
      return &tabs_;
    }

    PanesController* panes() noexcept {
      return &panes_;
    }

    ActivityController* activity() noexcept {
      return &activity_;
    }

    SidebarController* sidebar() noexcept {
      return &sidebar_;
    }

    PaletteController* palette() noexcept {
      return &palette_;
    }

    WorkspaceFormController* workspaceForm() noexcept {
      return &workspace_form_;
    }

    PathPickerController* paths() noexcept {
      return &paths_;
    }

    MachinePromptController* machinePrompt() noexcept {
      return &machine_prompt_;
    }

    MachineChromeController* machineChrome() noexcept {
      return &machine_chrome_;
    }

    PeekController* peek() noexcept {
      return &peek_;
    }

    PromptController* prompt() noexcept {
      return &prompt_;
    }

    DocumentsController* documents() noexcept {
      return &documents_;
    }

    LinkStatusController* linkStatus() noexcept {
      return &link_status_;
    }

    CopyController* copy() noexcept {
      return &copy_;
    }

    TerminalController* terminals() noexcept {
      return &terminals_;
    }

    NotificationsController* notifications() noexcept {
      return &notifications_;
    }

    ComponentsController* components() noexcept {
      return &components_;
    }

    HistoryController* history() noexcept {
      return &history_;
    }

    [[nodiscard]] QVariantMap colors() const;
    [[nodiscard]] QVariantMap font() const;
    [[nodiscard]] QVariantList commands() const;
    // A click on a mod element: runs its action, URL or Lua function.
    Q_INVOKABLE void activateElement(const QString& slot, const QString& key, const QString& revision, int element);

  signals:
    // The attachment shelf's region or the attachment modal's layout moved.
    // A configuration was loaded or the theme changed: fonts, colors, keymap and mods.
    void configurationChanged();
    // The document a pane shows natively appeared, changed or went away.
    void notification(const QString& message);

  private:
    friend struct test::HistoryPresentation;
    friend struct test::FramePacing;
    friend struct test::ComponentActions;

    [[nodiscard]] BindingContext bindingContext() const;
    void executeBinding(BindingAction action, const ConfigurationSource::Actions* resolved = nullptr);
    void luaBindingFinished(KeyBindings::Hold hold, bool stale, const QString& error, const std::function<void()>& apply);
    void applyEffects(const ResolvedEffects<ApplicationAllocator>& effects);
    void executeNamedAction(const NamedActionDescription& named);
    void executeCommandTab(BindingAction action, const ConfigurationSource::Actions* resolved);
    void executeNotificationBinding(BindingAction action, const ConfigurationSource::Actions* resolved);
    void initializeComponents();
    void initializeElements();
    // The mod content a record carries for its slots, keyed by slot name.
    void refreshElementBars();
    void initializePicks();
    void openComponentPick(std::size_t index);
    void initializePlugins();
    void initializePrompt();
    void initializeTerminals();
    void applyPluginEffects(const PluginEffects& effects);
    void applyExpression(const InputExpression& expression);
    void scrollBinding(ScrollDirection direction);
    [[nodiscard]] QString bindingShortcut(BindingActionKind action) const;

    bool executeMachineAction(window_actions::Action action);
    [[nodiscard]] GuiSession& session() noexcept;
    [[nodiscard]] const GuiSession& session() const noexcept;
    [[nodiscard]] RuntimeConnection& connection() noexcept;
    [[nodiscard]] const RuntimeConnection& connection() const noexcept;
    void runtimeDisconnected(MachineClient& client);
    void cancelCurrentInteraction();
    void initializePalette();
    // Pushes the display the controllers measure what they draw in.
    void measureDisplay();

    // Answers the commands of the active machine's client. A configuration reply views the
    // application's buffers, region `a`, until the client encodes it.
    struct HostCommands final : ClientCommandHandler {
      HostCommands(tbc::view<ApplicationController&, tbc::lt::a> owner, bool is_active) noexcept
          : application(owner),
            active(is_active) {}

      void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const override;

      tbc::view<ApplicationController&, tbc::lt::a> application;
      bool active = false;
    };

    void consume(MachineClient& client, QByteArrayView payload);
    [[nodiscard]] static bool answerConfiguration(tbc::view<ApplicationController&, tbc::lt::a> application, const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply);
    void executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply);
    void synchronizeDisplay();
    void synchronizeScreen();
    void synchronizeWindowSize();
    // Names the animated item types, in the order every window samples them.
    static void composeWindowAnimation() noexcept;
    void refresh();
    // Drops the theme and font QML reads and notifies a new configuration.
    void publishConfiguration();
    void presentChange(Change change);
    void initializeAttachments();
    void refreshPanes();
    void configureWindow();
    void synchronizeCadence();
    void initializeNotifications();
    void initializeGraphicsRecovery();
    void scheduleGraphicsRecovery();
    void restoreTerminalFocus();
    bool executeNavigation(window_actions::Action action, const QString& target);
    bool executePane(window_actions::Action action, std::uint64_t identity);
    void executeWindowAction(window_actions::Action action);
    // What the machines ask of the window.
    void attend(MachineClient& client) override;
    void dismiss(MachineClient& client) override;
    void releaseInput() override;
    void forgetView() override;
    void presentMachine() override;
    // What the terminals ask of the window (terminal_host.cpp).
    void pressKey(TerminalItem& terminal, QKeyEvent& event) override;
    [[nodiscard]] bool releaseKey(TerminalItem& terminal, QKeyEvent& event) override;
    void interruptKeys() override;
    void focusPane(TerminalItem& terminal) override;
    void ungrabPointer(TerminalItem& terminal) override;
    void openLink(const LinkTarget& target, std::uint64_t pane_id) override;

    // Runs a user's mutation of the session, then commits it to the store, whose interacted()
    // publishes what the mutation wrote and refreshes the window.
    template <std::invocable Mutation>
    void applyInteraction(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        interactionFailed(error);
      });
    }

    void interacted();
    void interactionFailed(const std::exception& error);
    // Brings every projection that reads the store up to date, in the order they depend on each
    // other; each one rebuilds only what moved since its last pass.
    void synchronize();

    ApplicationAllocator& memory_;
    Store store_;
    tbc::view<HistoryController, tbc::lt::self> history_;

    ConfigurationSource configuration_source_;
    tbc::view<WindowDisplay, tbc::lt::self> display_;
    // The theme and font QML reads, built on first read after each configurationChanged.
    mutable std::optional<QVariantMap> colors_;
    mutable std::optional<QVariantMap> font_;
    tbc::view<ElementSlots, tbc::lt::self> element_slots_{configuration_source_, [this] {
                                                            return components_.context();
                                                          },
        this};
    // Where the pressed component action that is running was pressed, for a panel it opens.
    std::optional<QPointF> component_action_anchor_;
    MachineProfilesSource machine_profiles_;
    tbc::view<AttachmentsController, tbc::lt::self> attachments_;
    tbc::view<SoundPlayer<ApplicationSoundHost, ApplicationController>, tbc::lt::self> sound_player_;
    SystemNotifier<ApplicationNotificationHost, ApplicationAllocator> system_notifier_;
    // What every client's MachineEffects reaches on the desktop.
    tbc::view<ApplicationEffects, tbc::lt::self> effects_;
    tbc::view<WorkspacesController, tbc::lt::self> workspaces_;
    tbc::view<TabsController, tbc::lt::self> tabs_;
    tbc::view<PanesController, tbc::lt::self> panes_;
    tbc::view<ActivityController, tbc::lt::self> activity_;
    tbc::view<SidebarController, tbc::lt::self> sidebar_;
    tbc::view<PaletteController, tbc::lt::self> palette_;
    tbc::view<PathPickerController, tbc::lt::self> paths_;
    tbc::view<MachinePromptController, tbc::lt::self> machine_prompt_;
    tbc::view<MachineChromeController, tbc::lt::self> machine_chrome_;
    tbc::view<PeekController, tbc::lt::self> peek_;
    tbc::view<PromptController, tbc::lt::self> prompt_;
    tbc::view<DocumentsController, tbc::lt::self> documents_;
    tbc::view<LinkStatusController, tbc::lt::self> link_status_;
    tbc::view<LinksController, tbc::lt::self> links_;
    tbc::view<CopyController, tbc::lt::self> copy_;
    // After the copy mode and the prompt, which the terminals read.
    tbc::view<TerminalController, tbc::lt::self> terminals_;
    tbc::view<NotificationsController, tbc::lt::self> notifications_;
    tbc::view<ComponentsController, tbc::lt::self> components_;
    tbc::view<PluginRunner, tbc::lt::self> plugins_;
    tbc::view<WorkspaceFormController, tbc::lt::self> workspace_form_;
    // The routers come after every recipient they hold, so they never outlive one.
    tbc::view<KeyBindings, tbc::lt::self> key_bindings_;
    tbc::view<PointerDispatcher, tbc::lt::self> pointer_dispatcher_;
    // After the copy mode and the keys, whose mode it reports.
    tbc::view<WindowStatus, tbc::lt::self> status_;
    // After every recipient of a frame.
    tbc::view<FramePresenter, tbc::lt::self> frames_;
    // After every controller a dialog opens over, and the routers it interrupts.
    tbc::view<Dialogs, tbc::lt::self> dialogs_;
    tbc::view<MachinesCoordinator, tbc::lt::self> machines_;
    tbc::view<MachineRoster, tbc::lt::self> roster_;
    tbc::view<ActivitySelection, tbc::lt::self> activity_selection_;
    QTimer refresh_timer_;
    QTimer graphics_resume_timer_;

    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
    QMetaObject::Connection screen_refresh_connection_;
  };

}
