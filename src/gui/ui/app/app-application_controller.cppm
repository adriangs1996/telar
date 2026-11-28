export module telar.gui.ui.app:application_controller;

import std;
import telar.gui.qt;
import telar.tbc;
import :activity_selection;
import :application_effects;
import :dialogs;
import :frame_presenter;
import :key_bindings;
import :machine_roster;
import :machines_coordinator;
import :pointer_dispatcher;
import telar.gui.ui.app.chrome.activity;
import telar.gui.ui.app.chrome.components;
import telar.gui.ui.app.chrome.components.machine_chrome;
import telar.gui.ui.app.chrome;
import telar.gui.ui.app.chrome.tabs;
import telar.gui.ui.app.chrome.workspaces;
import telar.gui.ui.app.overlays.explorer;
import telar.gui.ui.app.overlays.link_status;
import telar.gui.ui.app.overlays.machine_prompt.machine_profiles_source;
import telar.gui.ui.app.overlays.machine_prompt;
import telar.gui.ui.app.overlays.machine_wizard;
import telar.gui.ui.app.overlays.monitor;
import telar.gui.ui.app.overlays.notifications;
import telar.gui.ui.app.overlays.palette;
import telar.gui.ui.app.overlays.peek;
import telar.gui.ui.app.overlays.theme_picker;
import telar.gui.ui.app.overlays.workspace_form;
import telar.gui.ui.app.panes.attachments;
import telar.gui.ui.app.panes.documents;
import telar.gui.ui.app.panes.nvim;
import telar.gui.ui.app.panes;
import telar.gui.ui.app.panes.terminal;
import telar.gui.ui.app.panes.terminal.history;
import telar.gui.ui.app.panes.terminal.prompt;
import telar.gui.ui.design.elements;
import telar.gui.ui.kit.config;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.links;
import telar.gui.ui.kit.machines;
import telar.gui.ui.kit.paths;
import telar.gui.ui.kit.plugins;
import telar.gui.ui.kit.store;
import :window_commands;
import :window_display;
import :window_status;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;
import telar.base.memory.allocators;

extern "C++" namespace telar::gui::test {
  struct HistoryPresentation;
  struct FramePacing;
  struct ComponentActions;
  struct MachineWindow;
  struct MachineProfileWindow;
}

export namespace telar::gui::qt {

  // The window: it owns the store and every part that reads it, connects what each part asks
  // of the others, and keeps them up to date with the runtime in the order they depend on each
  // other.
  //
  // Each feature's state lives in its own controller, and what crosses features in its own
  // coordinator: the display, the status, the frames, the dialogs, the machines, the chosen
  // activity and the commands. None of them calls back here except through the narrow
  // interfaces this class implements for the terminals, the machines and the commands.
  class [[qt::object, qt_qml_named("ApplicationController"), qt_qml_uncreatable("Use the running GUI controller")]] ApplicationController final : public QObject, private TerminalHost, private NvimHost, private MachinesHost, private CommandsHost {
    friend struct test::MachineWindow;
    friend struct test::MachineProfileWindow;

  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

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

    [[tbc::hot_path]] inline WorkspacesController* workspaces() noexcept {
      return &workspaces_;
    }

    [[tbc::hot_path]] inline WindowDisplay* display() noexcept {
      return &display_;
    }

    [[tbc::hot_path]] inline WindowStatus* status() noexcept {
      return &status_;
    }

    [[tbc::hot_path]] inline Dialogs* dialogs() noexcept {
      return &dialogs_;
    }

    [[tbc::hot_path]] inline MachinesCoordinator* machines() noexcept {
      return &machines_;
    }

    [[tbc::hot_path]] inline MachineRoster* roster() noexcept {
      return &roster_;
    }

    [[tbc::hot_path]] inline WindowCommands* commands() noexcept {
      return &commands_;
    }

    [[tbc::hot_path]] inline TabsController* tabs() noexcept {
      return &tabs_;
    }

    [[tbc::hot_path]] inline PanesController* panes() noexcept {
      return &panes_;
    }

    [[tbc::hot_path]] inline ActivityController* activity() noexcept {
      return &activity_;
    }

    [[tbc::hot_path]] inline SidebarController* sidebar() noexcept {
      return &sidebar_;
    }

    [[tbc::hot_path]] inline PaletteController* palette() noexcept {
      return &palette_;
    }

    [[tbc::hot_path]] inline WorkspaceFormController* workspaceForm() noexcept {
      return &workspace_form_;
    }

    [[tbc::hot_path]] inline PathPickerController* paths() noexcept {
      return &paths_;
    }

    [[tbc::hot_path]] inline MachinePromptController* machinePrompt() noexcept {
      return &machine_prompt_;
    }

    [[tbc::hot_path]] inline MachineWizardController* machineWizard() noexcept {
      return &machine_wizard_;
    }

    [[tbc::hot_path]] inline MachineChromeController* machineChrome() noexcept {
      return &machine_chrome_;
    }

    [[tbc::hot_path]] inline PeekController* peek() noexcept {
      return &peek_;
    }

    [[tbc::hot_path]] inline MonitorController* monitor() noexcept {
      return &monitor_;
    }

    [[tbc::hot_path]] inline ExplorerController* explorer() noexcept {
      return &explorer_;
    }

    [[tbc::hot_path]] inline ThemePickerController* themes() noexcept {
      return &theme_picker_;
    }

    [[tbc::hot_path]] inline PromptController* prompt() noexcept {
      return &prompt_;
    }

    [[tbc::hot_path]] inline DocumentsController* documents() noexcept {
      return &documents_;
    }

    [[tbc::hot_path]] inline LinkStatusController* linkStatus() noexcept {
      return &link_status_;
    }

    [[tbc::hot_path]] inline CopyController* copy() noexcept {
      return &copy_;
    }

    [[tbc::hot_path]] inline TerminalController* terminals() noexcept {
      return &terminals_;
    }

    [[tbc::hot_path]] inline NvimController* editors() noexcept {
      return &editors_;
    }

    [[tbc::hot_path]] inline NotificationsController* notifications() noexcept {
      return &notifications_;
    }

    [[tbc::hot_path]] inline ComponentsController* components() noexcept {
      return &components_;
    }

    [[tbc::hot_path]] inline HistoryController* history() noexcept {
      return &history_;
    }

    [[nodiscard]] QVariantMap colors() const;
    [[nodiscard]] QVariantMap font() const;

    // A configuration was loaded or the theme changed: fonts, colors, keymap and mods.
    [[qt::signal]] void configurationChanged();
    // Something to tell the user that no dialog shows.
    [[qt::signal]] void notification(const QString& message);

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
    struct [[tbc::shared]] ThemeCache {
      ds::Option<QVariantMap> colors;
      ds::Option<QVariantMap> font;
    };

    mutable ThemeCache cache_;
    [[tbc::hot_path]] tbc::val_self<ElementSlots> element_slots_{configuration_source_, [this] {
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

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("attachments", &ApplicationController::attachments).constant(),
        telar::qt::property("display", &ApplicationController::display).constant(),
        telar::qt::property("status", &ApplicationController::status).constant(),
        telar::qt::property("dialogs", &ApplicationController::dialogs).constant(),
        telar::qt::property("machines", &ApplicationController::machines).constant(),
        telar::qt::property("commands", &ApplicationController::commands).constant(),
        telar::qt::property("workspaces", &ApplicationController::workspaces).constant(),
        telar::qt::property("tabs", &ApplicationController::tabs).constant(),
        telar::qt::property("panes", &ApplicationController::panes).constant(),
        telar::qt::property("activity", &ApplicationController::activity).constant(),
        telar::qt::property("sidebar", &ApplicationController::sidebar).constant(),
        telar::qt::property("history", &ApplicationController::history).constant(),
        telar::qt::property("controlModifier", &ApplicationController::controlModifier).constant(),
        telar::qt::property("superModifier", &ApplicationController::superModifier).constant(),
        telar::qt::property("colors", &ApplicationController::colors).withNotify(&ApplicationController::configurationChanged),
        telar::qt::property("font", &ApplicationController::font).withNotify(&ApplicationController::configurationChanged),
        telar::qt::property("components", &ApplicationController::components).constant(),
        telar::qt::property("copy", &ApplicationController::copy).constant(),
        telar::qt::property("terminals", &ApplicationController::terminals).constant(),
        telar::qt::property("editors", &ApplicationController::editors).constant(),
        telar::qt::property("notifications", &ApplicationController::notifications).constant(),
        telar::qt::property("machinePrompt", &ApplicationController::machinePrompt).constant(),
        telar::qt::property("machineWizard", &ApplicationController::machineWizard).constant(),
        telar::qt::property("machineChrome", &ApplicationController::machineChrome).constant(),
        telar::qt::property("peek", &ApplicationController::peek).constant(),
        telar::qt::property("monitor", &ApplicationController::monitor).constant(),
        telar::qt::property("explorer", &ApplicationController::explorer).constant(),
        telar::qt::property("themes", &ApplicationController::themes).constant(),
        telar::qt::property("prompt", &ApplicationController::prompt).constant(),
        telar::qt::property("documents", &ApplicationController::documents).constant(),
        telar::qt::property("linkStatus", &ApplicationController::linkStatus).constant(),
        telar::qt::property("palette", &ApplicationController::palette).constant(),
        telar::qt::property("paths", &ApplicationController::paths).constant(),
        telar::qt::property("workspaceForm", &ApplicationController::workspaceForm).constant()
    );
  };

}
