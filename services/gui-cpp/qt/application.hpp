#pragma once

#include "application_effects.hpp"
#include "configuration_source.hpp"
#include "core/calendar_sample.hpp"
#include "core/metrics.hpp"
#include "core/terminal_size.hpp"
#include "core/view_version.hpp"
#include "external_link_opener.hpp"
#include "font_resolver.hpp"
#include "history/choice.hpp"
#include "input/history_scroll.hpp"
#include "key_bindings.hpp"
#include "list_model.hpp"
#include "machine_activity_target.hpp"
#include "machine_client.hpp"
#include "machine_client_key.hpp"
#include "machine_profiles_source.hpp"
#include "machines/machines.hpp"
#include "machines/picker_target.hpp"
#include "machines/profile.hpp"
#include "palette/navigation_target.hpp"
#include "palette/query.hpp"
#include "palette/ranked_matches.hpp"
#include "pointer_dispatcher.hpp"
#include "presentation/display_metrics.hpp"
#include "presentation/frame_pacer.hpp"
#include "presentation/history_modal_geometry.hpp"
#include "presentation/palette_row_window.hpp"
#include "presentation/path_picker_placement.hpp"
#include "presentation/tab_caption.hpp"
#include "runtime_connection.hpp"
#include "scroll_event.hpp"
#include "sound_player.hpp"
#include "system_notifier.hpp"
#include "terminal_preparation.hpp"
#include "text/bounded_text.hpp"
#include "window_frame_pacer.hpp"
#include <QByteArray>
#include <QColor>
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>
#include <QWheelEvent>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <string_view>
#include <variant>

namespace telar::gui::test {
struct HistoryPresentation;
struct FramePacing;
struct MachineWindow;
struct MachineProfileWindow;
}

namespace telar::gui::qt {

class TerminalItem;
class MachineChromeLayout;

class Application final : public QObject {
  friend struct ApplicationEffects;
  friend class MachineChromeLayout;
  friend struct test::MachineWindow;
  friend struct test::MachineProfileWindow;

  Q_OBJECT
  QML_NAMED_ELEMENT(GuiController)
  QML_UNCREATABLE("Use the running GUI controller")
  Q_PROPERTY(QAbstractItemModel *workspaces READ workspaces CONSTANT)
  Q_PROPERTY(QAbstractItemModel *tabs READ tabs CONSTANT)
  Q_PROPERTY(QAbstractItemModel *panes READ panes CONSTANT)
  Q_PROPERTY(QAbstractItemModel *dividers READ dividers CONSTANT)
  Q_PROPERTY(QAbstractItemModel *agents READ agents CONSTANT)
  Q_PROPERTY(QAbstractItemModel *history READ history CONSTANT)
  Q_PROPERTY(bool historyLoading READ historyLoading NOTIFY historyChanged)
  Q_PROPERTY(QVariantMap historyState READ historyState NOTIFY historyChanged)
  Q_PROPERTY(QVariantMap historyGeometry READ historyGeometry NOTIFY historyChanged)
  Q_PROPERTY(QString historyCommand READ historyCommand NOTIFY historyChanged)
  Q_PROPERTY(QString historyOutput READ historyOutput NOTIFY historyChanged)
  Q_PROPERTY(QVariantMap historyInspection READ historyInspection NOTIFY historyChanged)
  Q_PROPERTY(int controlModifier READ controlModifier CONSTANT)
  Q_PROPERTY(int superModifier READ superModifier CONSTANT)
  Q_PROPERTY(QVariantMap colors READ colors NOTIFY configurationChanged)
  Q_PROPERTY(QVariantMap font READ font NOTIFY configurationChanged)
  Q_PROPERTY(qreal chromeRatio READ chromeRatio NOTIFY configurationChanged)
  Q_PROPERTY(qreal chromeTextScale READ chromeTextScale NOTIFY configurationChanged)
  Q_PROPERTY(QVariantMap windowGeometry READ windowGeometry NOTIFY windowGeometryChanged)
  Q_PROPERTY(QVariantMap runtimeLinkState READ runtimeLinkState NOTIFY runtimeLinkChanged)
  Q_PROPERTY(QVariantMap runtimeLinkGeometry READ runtimeLinkGeometry NOTIFY runtimeLinkChanged)
  Q_PROPERTY(QVariantMap sidebarGeometry READ sidebarGeometry NOTIFY sidebarGeometryChanged)
  Q_PROPERTY(QVariantMap workspaceContext READ workspaceContext NOTIFY stateChanged)
  Q_PROPERTY(bool sidebarVisible READ sidebarVisible NOTIFY configurationChanged)
  Q_PROPERTY(qreal sidebarWidth READ sidebarWidth NOTIFY configurationChanged)
  Q_PROPERTY(bool workspaceListCollapsed READ workspaceListCollapsed NOTIFY configurationChanged)
  Q_PROPERTY(qreal windowControls READ windowControls NOTIFY windowGeometryChanged)
  Q_PROPERTY(QString title READ title NOTIFY stateChanged)
  Q_PROPERTY(QVariantMap statusMode READ statusMode NOTIFY statusModeChanged)
  Q_PROPERTY(QVariantMap hostMetrics READ hostMetrics NOTIFY hostMetricsChanged)
  Q_PROPERTY(QString error READ error NOTIFY stateChanged)
  Q_PROPERTY(QString tlsBadgeColor READ tlsBadgeColor NOTIFY stateChanged)
  Q_PROPERTY(bool connected READ connected NOTIFY stateChanged)
  Q_PROPERTY(bool copyModeActive READ copyModeActive NOTIFY stateChanged)
  Q_PROPERTY(bool prefixPending READ prefixPending NOTIFY prefixChanged)
  Q_PROPERTY(QString dialog READ dialog NOTIFY dialogChanged)
  Q_PROPERTY(QString dialogText READ dialogText NOTIFY dialogChanged)
  Q_PROPERTY(QVariantList commands READ commands NOTIFY configurationChanged)
  Q_PROPERTY(QVariantMap machinePromptState READ machinePromptState NOTIFY machinePromptChanged)
  Q_PROPERTY(QVariantMap machinePromptGeometry READ machinePromptGeometry NOTIFY machinePromptChanged)
  Q_PROPERTY(QVariantMap peekState READ peekState NOTIFY peekChanged)
  Q_PROPERTY(QVariantMap peekGeometry READ peekGeometry NOTIFY peekChanged)
  Q_PROPERTY(QString activityHover READ activityHover NOTIFY activityHoverChanged)
  Q_PROPERTY(QVariantMap paletteState READ paletteState NOTIFY paletteChanged)
  Q_PROPERTY(QVariantMap paletteGeometry READ paletteGeometry NOTIFY paletteChanged)
  Q_PROPERTY(QVariantMap suggestionState READ suggestionState NOTIFY paletteChanged)
  Q_PROPERTY(QVariantMap suggestionGeometry READ suggestionGeometry NOTIFY paletteChanged)
  Q_PROPERTY(QVariantMap pathPickerState READ pathPickerState NOTIFY pathPickerChanged)
  Q_PROPERTY(QVariantMap pathPickerGeometry READ pathPickerGeometry NOTIFY pathPickerGeometryChanged)

public:
  enum class Action : quint8 {
    none,
    new_tab,
    select_tab,
    select_tab_index,
    next_tab,
    previous_tab,
    move_tab_next,
    move_tab_previous,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    resize_left,
    resize_right,
    resize_up,
    resize_down,
    detach,
    close_tab,
    select_workspace,
    focus_pane,
    select_agent,
    split_horizontal,
    split_vertical,
    close_pane,
    fullscreen,
    toggle_sidebar,
    toggle_workspace_list,
    history,
    palette,
    goto_picker,
    leave_worktree,
    forget_gone_worktrees,
    new_workspace,
    rename_tab,
    rename_workspace,
    cancel,
    copy_mode,
    path_picker,
    suggest_command,
    machine_picker,
    next_machine,
    previous_machine,
    add_machine,
  };
  Q_ENUM(Action)

  enum class MachineEditAction : quint8 {
    rename,
    remove,
  };
  Q_ENUM(MachineEditAction)

  Q_INVOKABLE void editMachineResult(const QVariantMap &choice, MachineEditAction action);
  Q_INVOKABLE void searchMachinePrompt(const QString &text);
  Q_INVOKABLE void submitMachinePrompt(const QString &revision);
  Q_INVOKABLE void reportMachinePromptLimit(qulonglong requested_bytes);
  [[nodiscard]] QVariantMap machinePromptState() const;
  [[nodiscard]] QVariantMap machinePromptGeometry() const;
  Q_INVOKABLE void peekActivity(const QString &identity);
  Q_INVOKABLE void searchPeek(const QString &text);
  Q_INVOKABLE void submitPeek(const QString &revision);
  Q_INVOKABLE void reportPeekLimit(qulonglong requested_bytes);
  [[nodiscard]] QVariantMap peekState() const;
  [[nodiscard]] QVariantMap peekGeometry() const;
  [[nodiscard]] QString activityHover() const;

  enum class HistoryAction : quint8 {
    copy,
    erase,
    visit,
    inspect,
    older,
    newer,
  };
  Q_ENUM(HistoryAction)

  explicit Application(ApplicationAllocator &memory, QObject *parent = nullptr);
  ~Application() override;
  Application(const Application &) = delete;
  Application &operator=(const Application &) = delete;
  Application(Application &&) = delete;
  Application &operator=(Application &&) = delete;

  void open(const QString &endpoint);
  void openMachines(const QString &path);
  void loadConfiguration(const QString &path, const QString &profile, const QString &theme);
  void configureLaunch(const QString &directory, const QStringList &arguments, bool restore);
  void configureRemoteLaunch(const QString &destination, const QStringList &arguments);
  void setWindow(QQuickWindow &window);
  bool eventFilter(QObject *watched, QEvent *event) override;
  [[nodiscard]] Pane<ApplicationAllocator> *pane(std::uint64_t identity) const noexcept;
  [[nodiscard]] const Configuration &configuration() const noexcept;
  [[nodiscard]] ResolvedFont resolveFont(qreal scale);
  [[nodiscard]] ViewVersion viewVersion() const noexcept;
  [[nodiscard]] Qt::KeyboardModifiers pointerModifiers() const noexcept;
  void observePointerModifiers(Qt::KeyboardModifiers modifiers);
  void registerTerminal(TerminalItem &terminal);
  void unregisterTerminal(TerminalItem &terminal);
  [[nodiscard]] const NotificationCenter &notifications() const noexcept;
  [[nodiscard]] QString notificationIdentity(NotificationId identity) const;
  [[nodiscard]] bool notificationTargetVisible(NotificationTarget target) const noexcept;
  [[nodiscard]] DisplayMetrics displayMetrics(qreal density) const;
  [[nodiscard]] Rect notificationHost(const DisplayMetrics &display) const;
  void publishNotification(NotificationInput input);
  void soundPlaybackFinished(std::optional<CommandFailure> failure);
  Q_INVOKABLE void dismissNotification(const QString &identity);
  Q_INVOKABLE void activateNotification(const QString &identity);
  Q_INVOKABLE void retireNotificationFocus(const QString &identity, QQuickItem *retiring_owner = nullptr);
  [[nodiscard]] PointerDispatcher &pointerDispatcher() noexcept;
  [[nodiscard]] std::shared_ptr<const LinkHit> shareLinkHit(const LinkHit &hit);

  Q_INVOKABLE void execute(Action action, const QString &target = {});
  Q_INVOKABLE void submitDialog(const QVariantMap &input);
  Q_INVOKABLE void useHistory(const QString &entry_id, bool alternate = false);
  Q_INVOKABLE void useHistoryRow(int row, bool alternate = false);
  Q_INVOKABLE void usePresentedHistory(const QString &revision, bool alternate = false);
  [[nodiscard]] bool historyLoading() const;
  [[nodiscard]] QString historyCommand() const;
  [[nodiscard]] QVariantMap historyState() const;
  [[nodiscard]] QString historyOutput() const;
  [[nodiscard]] QVariantMap historyInspection() const;
  [[nodiscard]] static int controlModifier();
  [[nodiscard]] static int superModifier();
  Q_INVOKABLE void executeHistory(HistoryAction action, const QString &entry_id = {});
  Q_INVOKABLE void selectHistoryRow(int row);
  Q_INVOKABLE void selectPresentedHistoryRow(int row, const QString &revision);
  Q_INVOKABLE void registerHistoryPanel(QQuickItem *panel);
  Q_INVOKABLE void setHistoryFilters(const QVariantMap &filters);
  Q_INVOKABLE void setSidebarWidth(qreal width);
  Q_INVOKABLE void searchHistory(const QString &query);
  Q_INVOKABLE void reportHistoryQueryLimit(qulonglong requested_bytes);
  Q_INVOKABLE void searchPalette(const QString &text);
  Q_INVOKABLE void searchPaths(const QString &text);
  Q_INVOKABLE void reportPathQueryLimit(qulonglong requested_bytes);
  Q_INVOKABLE void movePathSelection(int delta);
  Q_INVOKABLE void descendPath();
  Q_INVOKABLE void ascendPath();
  Q_INVOKABLE void insertPath(bool absolute);
  Q_INVOKABLE void activatePath(const QVariantMap &choice);
  Q_INVOKABLE void reportPaletteQueryLimit(qulonglong requested_bytes);
  Q_INVOKABLE void movePalette(int delta);
  Q_INVOKABLE void setPaletteMode(int mode);
  Q_INVOKABLE void usePaletteResult(const QVariantMap &choice);
  Q_INVOKABLE void submitSuggestion(const QString &revision);
  Q_INVOKABLE void resizeDivider(int index, qreal x, qreal y, bool commit);

  void input(std::uint64_t pane_id, const QByteArray &bytes, PaneInputSource source = PaneInputSource::keyboard);
  void paste(std::uint64_t pane_id, const QString &text);
  void resize(std::uint64_t pane_id, TerminalSize size);
  void scroll(PaneScrollDelta delta);
  bool handleBindingKey(QKeyEvent &event, QQuickItem &recipient, bool captures = false);
  void interruptBindings();
  [[nodiscard]] bool copyModeActive() const noexcept;
  [[nodiscard]] const std::optional<CopyState> &copyState() const noexcept;
  bool handleCopyKey(std::uint64_t pane_id, const QKeyEvent &event);
  bool beginSelection(std::uint64_t pane_id, CopyPoint local);
  bool handleCopyPointer(const CopyPointerInput &input);
  void copySelection(std::uint64_t pane_id);
  bool openLink(const LinkTarget &target, std::optional<std::uint64_t> source_id = {});
  void linkOpeningFinished(MachineClientKey source, std::optional<LinkOpeningFailure> failure);

  QAbstractItemModel *workspaces() noexcept {
    return &workspaces_;
  }

  QAbstractItemModel *tabs() noexcept {
    return &tabs_;
  }

  QAbstractItemModel *panes() noexcept {
    return &panes_;
  }

  QAbstractItemModel *agents() noexcept {
    return &agents_;
  }

  QAbstractItemModel *dividers() noexcept {
    return &dividers_;
  }

  QAbstractItemModel *history() noexcept {
    return &history_;
  }

  [[nodiscard]] QVariantMap colors() const;
  [[nodiscard]] QVariantMap font() const;
  [[nodiscard]] QVariantList commands() const;
  [[nodiscard]] QVariantMap paletteState() const;
  [[nodiscard]] QVariantMap suggestionState() const;
  [[nodiscard]] QVariantMap suggestionGeometry() const;
  [[nodiscard]] QVariantMap paletteGeometry() const;
  [[nodiscard]] qreal chromeRatio() const;
  [[nodiscard]] qreal chromeTextScale() const;
  [[nodiscard]] QVariantMap windowGeometry() const;
  [[nodiscard]] QVariantMap runtimeLinkState() const;
  [[nodiscard]] QVariantMap runtimeLinkGeometry() const;
  [[nodiscard]] QVariantMap pathPickerState() const;
  [[nodiscard]] QVariantMap pathPickerGeometry() const;
  [[nodiscard]] QVariantMap historyGeometry() const;
  [[nodiscard]] QVariantMap sidebarGeometry() const;
  [[nodiscard]] QVariantMap workspaceContext() const;
  [[nodiscard]] bool sidebarVisible() const;
  [[nodiscard]] qreal sidebarWidth() const;
  [[nodiscard]] bool workspaceListCollapsed() const;
  [[nodiscard]] qreal windowControls() const;
  [[nodiscard]] QString title() const;
  [[nodiscard]] QVariantMap statusMode() const;
  [[nodiscard]] QVariantMap hostMetrics() const;
  [[nodiscard]] bool prefixPending() const noexcept;
  [[nodiscard]] QString error() const;
  [[nodiscard]] QString tlsBadgeColor() const;
  Q_INVOKABLE void dismissDiagnostic();
  [[nodiscard]] bool connected() const;
  [[nodiscard]] QString dialog() const;
  [[nodiscard]] QString dialogText() const;

signals:
  void historyInspectionScrolled(int lines);
  void prefixChanged();
  void historyChanged();
  void paletteChanged();
  void pathPickerChanged();
  void pathPickerGeometryChanged();
  void stateChanged();
  void statusModeChanged();
  void hostMetricsChanged();
  void configurationChanged();
  void windowGeometryChanged();
  void runtimeLinkChanged();
  void sidebarGeometryChanged();
  void dialogChanged();
  void terminalChanged(qulonglong pane_id);
  void pointerModifiersChanged();
  void inputReleasing(qulonglong pane_id);
  void notification(const QString &message);
  void notificationsChanged();
  void machineChanged();
  void machinesChanged();
  void machinePromptChanged();
  void peekChanged();
  void activityHoverChanged();
  void machineLaunchFailed(const QString &error);

private:
  friend struct test::HistoryPresentation;
  friend struct test::FramePacing;
  friend class KeyBindings;
  friend class PointerDispatcher;
  friend class TerminalItem;

  [[nodiscard]] BindingContext bindingContext() const;
  [[nodiscard]] std::optional<BindingRepeat> bindingRepeat(BindingAction action) const;
  bool runBinding(BindingAction action);
  void executeBinding(BindingAction action);
  void executeCommandTab(BindingAction action);
  void executeNotificationBinding(BindingAction action);
  void applyExpression(const InputExpression &expression);
  void scrollBinding(ScrollDirection direction);
  [[nodiscard]] QString bindingShortcut(BindingActionKind action) const;
  using PaletteTarget = std::variant<NavigationTarget, Action, MachinePickerTarget>;
  static constexpr std::size_t palette_capacity = WorkspaceReplica<ApplicationAllocator>::maximum_workspaces + GuiSession::maximum_workspace_tabs + AgentReplica<ApplicationAllocator>::capacity;
  using PaletteMatches = RankedMatches<PaletteTarget, palette_capacity>;

  enum class MachineRetirement : std::uint8_t {
    disabled,
    removed,
  };

  enum class MachinePromptMode : std::uint8_t {
    add_label,
    add_destination,
    rename,
  };

  struct MachinePrompt {
    MachinePromptMode mode = MachinePromptMode::add_label;
    QString text;
    QString label;
    std::optional<MachineToken> renamed;
  };

  struct RemoteLaunch {
    QString destination;
    QStringList arguments;
  };

  bool executeMachineAction(Action action);
  void moveMachine(int delta);
  void chooseMachine(MachinePickerTarget target, bool alternate);
  void showMachinePrompt(std::optional<MachineToken> renamed = {});
  void setupMachine(MachineToken target);
  void refreshMachinePicker();
  bool updateMachinePickerResults(std::string_view query);
  [[nodiscard]] QVariantMap machinePickerRecord(MachinePickerTarget target) const;
  [[nodiscard]] std::optional<MachinePickerTarget> chosenMachine(const QVariantMap &choice) const;
  [[nodiscard]] std::size_t machinePromptLimit() const noexcept;
  void initializeMachineProfiles();
  void applyMachineProfiles();
  void openRequestedMachine();
  void reconcileMachines();
  void reconcileMachine(const MachineProfile &profile);
  void admitMachine(Machines::Slot slot);
  void retireMachine(Machines::Slot slot, MachineRetirement reason);
  static void discoveredMachine(MachineClient &client, const RemoteDiscovery &discovery);
  void initializeMachines();
  void configureClients();
  void setClientsDisplayRefresh(std::uint16_t fps);
  [[nodiscard]] MachineClient &createClient(Machines::Slot slot);
  [[nodiscard]] MachineClient &clientAt(Machines::Slot slot) const noexcept;
  void selectMachine(MachineToken target);
  void releaseMachineInput();
  void forgetMachineView();
  void summarizeMachine(const MachineClient &client);
  void connectMachine(MachineClient &client);
  [[nodiscard]] MachineClient *findClient(MachineClientKey key) const noexcept;
  [[nodiscard]] GuiSession &session() noexcept;
  [[nodiscard]] const GuiSession &session() const noexcept;
  [[nodiscard]] RuntimeConnection &connection() noexcept;
  [[nodiscard]] const RuntimeConnection &connection() const noexcept;
  void runtimeDisconnected(MachineClient &client);
  void cancelCurrentInteraction();
  void showPalette(PaletteMode mode);
  void refreshPalette();
  bool restorePaletteParent();
  bool updatePaletteResults();
  void collectPaletteNavigation(PaletteMatches &matches, std::string_view query) const;
  [[nodiscard]] QVariantMap paletteRecord(const PaletteTarget &target, bool queried) const;
  bool navigatePaletteTarget(const NavigationTarget &target);
  void showPathPicker();
  void refreshPathPicker();
  [[nodiscard]] PathPickerPlacement pathPlacement() const;
  QString path_query_;
  std::size_t path_selection_ = 0;
  static constexpr Viewport default_viewport{.width = 1200, .height = 800, .scale = 1};

  struct PresentedPane {
    TerminalPreparation frame;
    QPointer<TerminalItem> terminal;
  };

  struct PresentedHistory {
    HistoryChoice choice;
    std::uint64_t dialog_generation = 0;
    bool enter_runs = false;
  };

  struct PresentedFrame {
    std::uint64_t machine_view = 0;
    std::array<PresentedPane, PaneLayout::maximum_panes> panes;
    std::size_t pane_count = 0;
    std::uint64_t preparation_ns = 0;
    std::optional<PresentedHistory> history;
    HistoryScrollSurface history_surface;
  };

  void consume(MachineClient &client, QByteArrayView payload);
  void executeHostCommand(const ClientCommand &message, CompleteClientCommand &reply);
  void synchronizeFontMetrics();
  void synchronizeWorkbenchGeometry();
  void synchronizeDisplay();
  void synchronizeScreen();
  void synchronizeWindowSize();
  bool updateViewport(qreal width, qreal height);
  void observeFrames(QQuickWindow &window);
  void submitHistory(std::uint64_t entry_id, bool alternate);
  [[nodiscard]] const PresentedHistory *presentedHistory(const QString &revision) const;
  void refreshHistory();
  [[nodiscard]] QString historyScopeValue();
  [[nodiscard]] std::string_view historyTabName(const Pane<ApplicationAllocator> *pane) const;
  void refresh();
  void refreshAgents();
  [[nodiscard]] bool activityAvailable(const MachineActivityTarget &target) const;
  void selectActivity(const QString &identity, bool peek = false);
  void settleActivity();
  [[nodiscard]] bool peekOriginValid() const;
  void refreshPeek();
  void openActivityPeek(const MachineActivityTarget &target, const QString &identity, std::uint64_t pointer_revision);
  void observeActivityPointer();
  void clearActivityHover();
  void presentChange(Change change);
  void refreshPanes();
  [[nodiscard]] HistoryModalMetrics historyMetrics() const;
  [[nodiscard]] HistoryScrollSurface historyScrollSurface(const HistoryModalMetrics &metrics) const;
  [[nodiscard]] bool handleHistoryWheel(QWheelEvent &event);
  void moveHistoryRows(std::int32_t steps);
  [[nodiscard]] QVariantList fullscreenEntries(const Tab<ApplicationAllocator> &tab);
  void showDialog(const QString &kind, const QString &text = {});
  void fail(const std::exception &error);
  void publishCopyChange(std::uint64_t previous_pane);
  void leaveKeyboardCopyMode();
  void openCopyLink(std::uint64_t pane_id, CellPosition point);
  void present(const PresentedFrame &frame);
  void prepareFrame(PresentedFrame &frame);
  void prepareTerminalFrames(PresentedFrame &frame);
  void recordPreparedFrame(const PresentedFrame &frame);
  [[nodiscard]] TerminalItem *visibleTerminal(std::uint64_t pane_id) const;
  [[nodiscard]] std::size_t collectPacingPanes(std::span<FramePacer::Pane, PaneLayout::maximum_panes> panes) const;
  void reconsiderFrame();
  void configureFramePacer();
  void prepareImagePlacements();
  void configureWindow();
  void synchronizeCadence();
  void refreshNotifications();
  void scheduleNotifications();
  void initializeNotifications();
  void initializeGraphicsRecovery();
  void scheduleGraphicsRecovery();
  void restoreTerminalFocus();
  [[nodiscard]] std::optional<NotificationId> resolveNotification(const QString &identity) const;
  bool executeNavigation(Action action, const QString &target);
  bool executePane(Action action, std::uint64_t identity);
  void executeWindowAction(Action action);

  template <std::invocable Mutation>
  void applyInteraction(Mutation mutate) {
    try {
      pending_activity_.reset();
      mutate();
      refresh();
    } catch (const std::exception &error) {
      if (dialog_ == QLatin1StringView("history")) {
        session().reportHistoryError(error.what());
        refreshHistory();
      } else {
        fail(error);
      }
    }
  }

  ApplicationAllocator &memory_;
  Machines machines_;
  std::array<std::optional<Owned<MachineClient, ApplicationAllocator>>, Machines::capacity> clients_;
  std::uint64_t next_client_generation_ = 1;
  std::uint64_t machine_view_revision_ = 0;
  struct ActivitySourceVersion {
    MachineClientKey source;
    std::uint64_t runtime_generation;
    std::uint64_t agents;
    std::uint64_t workspaces;
    bool connected;
    runtime::FixedText<MachineLimits::label_bytes> label;

    bool operator==(const ActivitySourceVersion &other) const noexcept {
      return source == other.source && runtime_generation == other.runtime_generation && agents == other.agents && workspaces == other.workspaces && connected == other.connected && label.view() == other.label.view();
    }
  };

  struct ActivitySelection {
    Machines::Slot slot;
    std::uint64_t tabs;
    std::uint64_t panes;

    bool operator==(const ActivitySelection &) const noexcept = default;
  };

  struct ActivityRowTarget {
    QString identity;
    MachineActivityTarget target;
  };

  struct PendingActivity {
    MachineActivityTarget target;
    std::uint64_t window;
    bool peek = false;
    std::uint64_t pointer_revision = 0;
  };

  struct PeekOrigin {
    MachineActivityTarget target;
    std::uint64_t window;
  };

  std::array<std::optional<ActivitySourceVersion>, Machines::capacity> activity_versions_;
  std::optional<ActivitySelection> activity_selection_;
  Vector<ActivityRowTarget, ApplicationAllocator> activity_targets_;
  std::optional<PendingActivity> pending_activity_;
  std::optional<PeekOrigin> peek_origin_;
  QString peek_editor_;
  QString activity_hover_;
  std::uint64_t pointer_revision_ = 0;
  std::optional<MachineClientKey> sound_owner_;
  ConfigurationSource configuration_source_;
  MachineProfilesSource machine_profiles_;
  std::optional<MachinePrompt> machine_prompt_;
  std::optional<RemoteLaunch> remote_launch_;
  QTimer machine_retry_;
  QString machine_control_endpoint_;
  bool prepare_machine_directory_ = false;
  bool sidebar_machine_row_shown_ = false;
  bool restore_layout_ = true;
  std::optional<WindowFramePacer<>> frame_pacer_;
  KeyBindings key_bindings_;
  PointerDispatcher pointer_dispatcher_;
  ExternalLinkOpener<ApplicationLinkHost, Application, MachineClientKey> link_opener_;
  SoundPlayer<ApplicationSoundHost, Application> sound_player_;
  SystemNotifier<ApplicationNotificationHost, ApplicationAllocator> system_notifier_;
  ListModel workspaces_;
  QVariantMap workspace_context_;
  ListModel tabs_;
  ListModel panes_;
  ListModel dividers_;
  ListModel agents_;
  ListModel history_;
  QString palette_query_;

  struct PaletteEditorPosition {
    int anchor = 0;
    int cursor = 0;
    std::uint64_t revision = 0;
  };

  struct PaletteParent {
    QString query;
    std::size_t selection = 0;
    PaletteEditorPosition editor;
  };

  std::optional<PaletteParent> palette_parent_;
  PaletteEditorPosition palette_editor_restore_;
  QVariantList palette_rows_;
  QVariantList palette_commands_;
  std::array<PaletteTarget, palette_capacity> palette_targets_{};
  std::array<PaletteRowKind, palette_capacity> palette_kinds_{};
  std::size_t palette_selection_ = 0;
  std::uint64_t palette_revision_ = 0;
  QTimer refresh_timer_;
  QTimer history_timer_;
  QTimer notification_timer_;
  QTimer graphics_resume_timer_;
  QString history_query_;
  CalendarSample history_calendar_;
  HistoryFilters history_filters_;
  std::uint64_t history_view_version_ = 0;
  std::uint64_t history_rows_version_ = 0;
  QByteArray history_directory_source_;
  QString history_directory_value_;
  QString history_scope_value_;
  BoundedText<TabCaption::capacity> history_tab_name_;
  bool history_pane_open_ = false;
  HistoryScroll history_scroll_;
  ScrollEventSequence history_wheel_sequence_;
  QPointer<QQuickItem> history_panel_;
  QPointer<QQuickItem> history_viewport_;
  QPointer<QQuickItem> history_content_;
  QPointer<QQuickItem> history_search_host_;
  QString error_;
  QString dialog_;
  QString dialog_text_;
  std::uint64_t dialog_generation_ = 0;
  QPointer<QQuickWindow> window_;
  std::uint64_t window_generation_ = 0;
  QMetaObject::Connection screen_refresh_connection_;
  Viewport viewport_ = default_viewport;
  CellMetrics cell_metrics_;
  TerminalGrid terminal_grid_;
  std::optional<PresentedHistory> presented_history_;
  HistoryScrollSurface presented_history_surface_;
  QHash<std::uint64_t, QPointer<TerminalItem>> terminals_;
  QByteArray hostname_;
  Qt::KeyboardModifiers pointer_modifiers_;
};

}
