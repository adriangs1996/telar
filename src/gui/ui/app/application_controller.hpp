#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "activity_selection.hpp"
#include "application_effects.hpp"
#include "dialogs.hpp"
#include "foundation/core/application_memory.hpp"
#include "frame_presenter.hpp"
#include "key_bindings.hpp"
#include "machine_roster.hpp"
#include "machines_coordinator.hpp"
#include "pointer_dispatcher.hpp"
#include "ui/app/chrome/activity/activity_controller.hpp"
#include "ui/app/chrome/components/components_controller.hpp"
#include "ui/app/chrome/components/machine_chrome/machine_chrome_controller.hpp"
#include "ui/app/chrome/sidebar_controller.hpp"
#include "ui/app/chrome/tabs/tabs_controller.hpp"
#include "ui/app/chrome/workspaces/workspaces_controller.hpp"
#include "ui/app/overlays/explorer/explorer_controller.hpp"
#include "ui/app/overlays/link_status/link_status_controller.hpp"
#include "ui/app/overlays/machine_prompt/machine_profiles_source.hpp"
#include "ui/app/overlays/machine_prompt/machine_prompt_controller.hpp"
#include "ui/app/overlays/machine_wizard/machine_wizard_controller.hpp"
#include "ui/app/overlays/monitor/monitor_controller.hpp"
#include "ui/app/overlays/notifications/notifications_controller.hpp"
#include "ui/app/overlays/notifications/sound_player.hpp"
#include "ui/app/overlays/notifications/system_notifier.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"
#include "ui/app/overlays/peek/peek_controller.hpp"
#include "ui/app/overlays/theme_picker/theme_picker_controller.hpp"
#include "ui/app/overlays/workspace_form/workspace_form_controller.hpp"
#include "ui/app/panes/attachments/attachments_controller.hpp"
#include "ui/app/panes/documents/documents_controller.hpp"
#include "ui/app/panes/nvim/nvim_controller.hpp"
#include "ui/app/panes/panes_controller.hpp"
#include "ui/app/panes/terminal/copy_controller.hpp"
#include "ui/app/panes/terminal/history/history_controller.hpp"
#include "ui/app/panes/terminal/prompt/prompt_controller.hpp"
#include "ui/app/panes/terminal/terminal_controller.hpp"
#include "ui/design/elements/element_slots.hpp"
#include "ui/kit/config/configuration_source.hpp"
#include "ui/kit/fonts/font_resolver.hpp"
#include "ui/kit/links/links_controller.hpp"
#include "ui/kit/machines/machine_client.hpp"
#include "ui/kit/machines/runtime_connection.hpp"
#include "ui/kit/paths/path_picker_controller.hpp"
#include "ui/kit/plugins/plugin_runner.hpp"
#include "ui/kit/store/store.hpp"
#include "window_commands.hpp"
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
#include <cstdint>
#include <optional>

#pragma once

#include "tbc/view.hpp"

import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::test {
  struct HistoryPresentation;
  struct FramePacing;
  struct ComponentActions;
  struct MachineWindow;
  struct MachineProfileWindow;
}

namespace telar::gui::qt {

  class TerminalItem;

  // The window: it owns the store and every part that reads it, connects what each part asks
  // of the others, and keeps them up to date with the runtime in the order they depend on each
  // other.
  //
  // Each feature's state lives in its own controller, and what crosses features in its own
  // coordinator: the display, the status, the frames, the dialogs, the machines, the chosen
  // activity and the commands. None of them calls back here except through the narrow
  // interfaces this class implements for the terminals, the machines and the commands.
  class ApplicationController final : public QObject, private TerminalHost, private NvimHost, private MachinesHost, private CommandsHost {
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
    Q_PROPERTY(telar::gui::qt::WindowCommands* commands READ commands CONSTANT)
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
    Q_PROPERTY(telar::gui::qt::NvimController* editors READ editors CONSTANT)
    Q_PROPERTY(telar::gui::qt::NotificationsController* notifications READ notifications CONSTANT)
    Q_PROPERTY(telar::gui::qt::MachinePromptController* machinePrompt READ machinePrompt CONSTANT)
    Q_PROPERTY(telar::gui::qt::MachineWizardController* machineWizard READ machineWizard CONSTANT)
    Q_PROPERTY(telar::gui::qt::MachineChromeController* machineChrome READ machineChrome CONSTANT)
    Q_PROPERTY(telar::gui::qt::PeekController* peek READ peek CONSTANT)
    Q_PROPERTY(telar::gui::qt::MonitorController* monitor READ monitor CONSTANT)
    Q_PROPERTY(telar::gui::qt::ExplorerController* explorer READ explorer CONSTANT)
    Q_PROPERTY(telar::gui::qt::ThemePickerController* themes READ themes CONSTANT)
    Q_PROPERTY(telar::gui::qt::PromptController* prompt READ prompt CONSTANT)
    Q_PROPERTY(telar::gui::qt::DocumentsController* documents READ documents CONSTANT)
    Q_PROPERTY(telar::gui::qt::LinkStatusController* linkStatus READ linkStatus CONSTANT)
    Q_PROPERTY(telar::gui::qt::PaletteController* palette READ palette CONSTANT)
    Q_PROPERTY(telar::gui::qt::PathPickerController* paths READ paths CONSTANT)
    Q_PROPERTY(telar::gui::qt::WorkspaceFormController* workspaceForm READ workspaceForm CONSTANT)

  public:
    using Dialog = Store::Dialog;

    explicit ApplicationController(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~ApplicationController() override;
    ApplicationController(const ApplicationController&) = delete;
    ApplicationController& operator=(const ApplicationController&) = delete;
    ApplicationController(ApplicationController&&) = delete;
    ApplicationController& operator=(ApplicationController&&) = delete;

    [[nodiscard]] AttachmentsController* attachments() noexcept;
    void loadConfiguration(const QString& path, const QString& profile, const QString& theme, const QString& trust_path = {}, const QString& theme_choice_path = {});
    void setWindow(QQuickWindow& window);
    bool eventFilter(QObject* watched, QEvent* event) override;
    [[nodiscard]] const application::Pane<Memory>* pane(std::uint64_t identity) const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    void soundPlaybackFinished(ds::Option<CommandFailure> failure);

    [[nodiscard]] static int controlModifier();
    [[nodiscard]] static int superModifier();

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

    WindowCommands* commands() noexcept {
      return &commands_;
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

    MachineWizardController* machineWizard() noexcept {
      return &machine_wizard_;
    }

    MachineChromeController* machineChrome() noexcept {
      return &machine_chrome_;
    }

    PeekController* peek() noexcept {
      return &peek_;
    }

    MonitorController* monitor() noexcept {
      return &monitor_;
    }

    ExplorerController* explorer() noexcept {
      return &explorer_;
    }

    ThemePickerController* themes() noexcept {
      return &theme_picker_;
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

    NvimController* editors() noexcept {
      return &editors_;
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

  signals:
    // A configuration was loaded or the theme changed: fonts, colors, keymap and mods.
    void configurationChanged();
    // Something to tell the user that no dialog shows.
    void notification(const QString& message);

  private:
    friend struct test::HistoryPresentation;
    friend struct test::FramePacing;
    friend struct test::ComponentActions;

    void initializeComponents();
    void initializeElements();
    void initializeCopy();
    void initializeOverlays();
    void initializeMachineChrome();
    void initializePeekAndMonitor();
    void initializeThemePicker();
    // The explorer changed: who takes the keys.
    void settleExplorer();
    // What the editor of a pane asked of the explorer since it was last seen to.
    void askExplorer(std::uint64_t pane_id);
    void yieldExplorer();
    void initializeConfigurationSource();
    // The mod content a record carries for its slots, keyed by slot name.
    void refreshElementBars();
    void initializePicks();
    void initializePlugins();
    void initializePrompt();
    void initializeTerminals();

    [[nodiscard]] GuiSession& sessionMut() noexcept;
    [[nodiscard]] const GuiSession& session() const noexcept;
    [[nodiscard]] RuntimeConnection& connectionMut() noexcept;
    [[nodiscard]] const RuntimeConnection& connection() const noexcept;
    // The client the key names is looked up, and again after each call that can change the store
    // holding it, as Rust indexes a collection its owner's own methods also change.
    void runtimeDisconnected(application::machines::MachineClientKey key);
    void initializePalette();
    // Pushes the display the controllers measure what they draw in.
    void measureDisplay();

    void consume(application::machines::MachineClientKey key, QByteArrayView payload);
    void synchronizeDisplay();
    void synchronizeScreen();
    void synchronizeWindowSize();
    // Names the animated item types, in the order every window samples them.
    static void composeWindowAnimation() noexcept;
    // Drops the theme and font QML reads and notifies a new configuration.
    void publishConfiguration();
    void presentChange(application::Change change);
    void initializeAttachments();
    void refreshPanes();
    void configureWindow();
    void synchronizeCadence();
    void initializeNotifications();
    void initializeGraphicsRecovery();
    void scheduleGraphicsRecovery();
    void restoreTerminalFocus();
    // What a command asks of the window.
    void refresh() override;
    void closeWindow() override;
    // What the machines ask of the window.
    void attend(MachineClient& client) override;
    void dismiss(MachineClient& client) override;
    void releaseInput() override;
    void forgetView() override;
    void presentMachine() override;
    // What the terminals ask of the window.
    void pressKey(TerminalItem& terminal, QKeyEvent& event) override;
    [[nodiscard]] bool releaseKey(TerminalItem& terminal, QKeyEvent& event) override;
    void interruptKeys() override;
    [[nodiscard]] ResolvedFont resolveFont(qreal scale) override;
    void focusPane(TerminalItem& terminal) override;
    void ungrabPointer(TerminalItem& terminal) override;
    void openLink(const application::terminal::links::LinkTarget& target, std::uint64_t pane_id) override;

    void interacted();
    // Brings every projection that reads the store up to date, in the order they depend on each
    // other; each one rebuilds only what moved since its last pass.
    void synchronize();

    ApplicationAllocator& memory_;
    Store store_;
    tbc::val_self<HistoryController> history_;

    ConfigurationSource configuration_source_;
    tbc::val_self<WindowDisplay> display_;
    // The theme and font QML reads, built on first read after each configurationChanged.
    mutable ds::Option<QVariantMap> colors_;
    mutable ds::Option<QVariantMap> font_;
    tbc::val_self<ElementSlots> element_slots_{configuration_source_, [this] {
                                                 return components_.context();
                                               },
        this};
    MachineProfilesSource machine_profiles_;
    tbc::val_self<AttachmentsController> attachments_;
    tbc::val_self<SoundPlayer<ApplicationSoundHost, ApplicationController>> sound_player_;
    SystemNotifier<ApplicationNotificationHost, ApplicationAllocator> system_notifier_;
    // What every client's MachineEffects reaches on the desktop.
    tbc::val_self<ApplicationEffects> effects_;
    tbc::val_self<WorkspacesController> workspaces_;
    tbc::val_self<TabsController> tabs_;
    tbc::val_self<PanesController> panes_;
    tbc::val_self<ActivityController> activity_;
    tbc::val_self<SidebarController> sidebar_;
    tbc::val_self<PaletteController> palette_;
    tbc::val_self<PathPickerController> paths_;
    tbc::val_self<MachinePromptController> machine_prompt_;
    tbc::val_self<MachineWizardController> machine_wizard_;
    tbc::val_self<MachineChromeController> machine_chrome_;
    tbc::val_self<PeekController> peek_;
    tbc::val_self<MonitorController> monitor_;
    tbc::val_self<ExplorerController> explorer_;
    tbc::val_self<ThemePickerController> theme_picker_;
    tbc::val_self<PromptController> prompt_;
    tbc::val_self<DocumentsController> documents_;
    tbc::val_self<LinkStatusController> link_status_;
    tbc::val_self<LinksController> links_;
    tbc::val_self<CopyController> copy_;
    // After the copy mode and the prompt, which the terminals read.
    tbc::val_self<TerminalController> terminals_;
    tbc::val_self<NvimController> editors_;
    tbc::val_self<NotificationsController> notifications_;
    tbc::val_self<ComponentsController> components_;
    tbc::val_self<PluginRunner> plugins_;
    tbc::val_self<WorkspaceFormController> workspace_form_;
    // The routers come after every recipient they hold, so they never outlive one. The keys also
    // hold the commands, built last: no key is routed once the window is being destroyed.
    tbc::val_self<KeyBindings> key_bindings_;
    tbc::val_self<PointerDispatcher> pointer_dispatcher_;
    // After the copy mode and the keys, whose mode it reports.
    tbc::val_self<WindowStatus> status_;
    // After every recipient of a frame.
    tbc::val_self<FramePresenter> frames_;
    // After every controller a dialog opens over, and the routers it interrupts.
    tbc::val_self<Dialogs> dialogs_;
    tbc::val_self<MachinesCoordinator> machines_;
    tbc::val_self<MachineRoster> roster_;
    tbc::val_self<ActivitySelection> activity_selection_;
    // After everything a command acts on; the key bindings hold it before it is built.
    tbc::val_self<WindowCommands> commands_;
    QTimer refresh_timer_;
    QTimer graphics_resume_timer_;

    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
    QMetaObject::Connection screen_refresh_connection_;
  };

}
