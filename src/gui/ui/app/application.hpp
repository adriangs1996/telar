#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "application_effects.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "input/wheel_accumulator.hpp"
#include "list_model.hpp"
#include "runtime_connection.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/protocol/clients.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "ui/activity/activity_controller.hpp"
#include "ui/attachments/attachment_shelf.hpp"
#include "ui/chrome/tabs_controller.hpp"
#include "ui/components/component_surface_state.hpp"
#include "ui/components/element_slots.hpp"
#include "ui/components/pick_controller.hpp"
#include "ui/components/surface_command.hpp"
#include "ui/config/configuration_source.hpp"
#include "ui/fonts/font_resolver.hpp"
#include "ui/history/history_controller.hpp"
#include "ui/input/key_bindings.hpp"
#include "ui/input/pointer_dispatcher.hpp"
#include "ui/input/scroll_event.hpp"
#include "ui/links/external_link_opener.hpp"
#include "ui/machines/machine_activity_target.hpp"
#include "ui/machines/machine_client.hpp"
#include "ui/machines/machine_client_key.hpp"
#include "ui/machines/machine_profiles_source.hpp"
#include "ui/notifications/sound_player.hpp"
#include "ui/notifications/system_notifier.hpp"
#include "ui/panes/panes_controller.hpp"
#include "ui/plugins/plugin_worker.hpp"
#include "ui/store/store.hpp"
#include "ui/terminal/terminal_preparation.hpp"
#include "ui/workspaces/workspaces_controller.hpp"
#include "window_frame_pacer.hpp"
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
import telar.gui.core.unicode_scalar;
import telar.gui.core.metrics;
import telar.gui.input.child_mouse;
import telar.gui.presentation.history_pointer;
import telar.gui.presentation.tab_drop;
import telar.gui.machines.picker;
import telar.gui.machines.profile_store;
import telar.gui.palette.navigation_label;
import telar.gui.paths.label;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.frame_pacer;
import telar.gui.presentation.history_meta_geometry;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.form_field_geometry;
import telar.gui.presentation.notification_center;
import telar.gui.prompt.routing;
import telar.gui.prompt.line;
import telar.gui.prompt.editor;
import telar.gui.input.copy_mode;
import telar.gui.model.replicas;
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
  class MachineChromeLayout;

  class Application final : public QObject {
    friend struct ApplicationEffects;
    friend class MachineChromeLayout;
    friend struct test::MachineWindow;
    friend struct test::MachineProfileWindow;

    Q_OBJECT
    QML_NAMED_ELEMENT(GuiController)
    QML_UNCREATABLE("Use the running GUI controller")
    // QML names every enum value with its enum, so Action::palette and Dialog::palette do not clash.
    Q_CLASSINFO("RegisterEnumClassesUnscoped", "false")
    Q_PROPERTY(AttachmentShelf* attachments READ attachments CONSTANT)
    Q_PROPERTY(QVariantMap attachmentGeometry READ attachmentGeometry NOTIFY attachmentGeometryChanged)
    Q_PROPERTY(QVariantMap attachmentModalGeometry READ attachmentModalGeometry NOTIFY attachmentGeometryChanged)
    Q_PROPERTY(telar::gui::qt::WorkspacesController* workspaces READ workspaces CONSTANT)
    Q_PROPERTY(telar::gui::qt::TabsController* tabs READ tabs CONSTANT)
    Q_PROPERTY(telar::gui::qt::PanesController* panes READ panes CONSTANT)
    Q_PROPERTY(telar::gui::qt::ActivityController* activity READ activity CONSTANT)
    Q_PROPERTY(telar::gui::qt::HistoryController* history READ history CONSTANT)
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
    Q_PROPERTY(QVariantMap machineContext READ machineContext NOTIFY machinesChanged)
    Q_PROPERTY(bool machineListCollapsed READ machineListCollapsed NOTIFY sidebarGeometryChanged)
    Q_PROPERTY(int machineCount READ machineCount NOTIFY machinesChanged)
    Q_PROPERTY(bool sidebarVisible READ sidebarVisible NOTIFY sidebarGeometryChanged)
    Q_PROPERTY(qreal sidebarWidth READ sidebarWidth NOTIFY sidebarGeometryChanged)
    Q_PROPERTY(bool workspaceListCollapsed READ workspaceListCollapsed NOTIFY sidebarGeometryChanged)
    Q_PROPERTY(qreal windowControls READ windowControls NOTIFY windowGeometryChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    Q_PROPERTY(QVariantMap statusMode READ statusMode NOTIFY statusModeChanged)
    Q_PROPERTY(QVariantMap hostMetrics READ hostMetrics NOTIFY hostMetricsChanged)
    Q_PROPERTY(QVariantMap componentBars READ componentBars NOTIFY componentsChanged)
    // Mod content for the top and bottom bars, by slot name; empty while QML draws them.
    Q_PROPERTY(QVariantMap elementBars READ elementBars NOTIFY elementBarsChanged)
    Q_PROPERTY(QVariantMap componentPanel READ componentPanel NOTIFY componentsChanged)
    Q_PROPERTY(QVariantMap componentPick READ componentPick NOTIFY pickChanged)
    Q_PROPERTY(QString error READ error NOTIFY diagnosticChanged)
    Q_PROPERTY(QString tlsBadgeColor READ tlsBadgeColor NOTIFY diagnosticChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY diagnosticChanged)
    Q_PROPERTY(bool copyModeActive READ copyModeActive NOTIFY copyModeChanged)
    Q_PROPERTY(bool prefixPending READ prefixPending NOTIFY prefixChanged)
    Q_PROPERTY(telar::gui::qt::Store::Dialog dialog READ dialog NOTIFY dialogChanged)
    // The command whose output the scrollback search reads, empty while it reads the whole
    // scrollback; and whether Tab can switch between the two.
    Q_PROPERTY(QString copySearchScope READ copySearchScope NOTIFY dialogChanged)
    Q_PROPERTY(bool copySearchScopes READ copySearchScopes NOTIFY dialogChanged)
    // The scrollback search as it is typed: its query, whether an answer is awaited, how many
    // matches and which one the cursor is on, and what it reads.
    Q_PROPERTY(QVariantMap copySearchState READ copySearchState NOTIFY copySearchChanged)
    // The history or path search the focused pane's prompt line hosts in place of the dialog.
    Q_PROPERTY(telar::gui::qt::Store::Dialog lineSearch READ lineSearch NOTIFY dialogChanged)
    Q_PROPERTY(QString lineSearchPane READ lineSearchPane NOTIFY dialogChanged)
    Q_PROPERTY(QVariantList commands READ commands NOTIFY configurationChanged)
    Q_PROPERTY(QVariantMap machinePromptState READ machinePromptState NOTIFY machinePromptChanged)
    Q_PROPERTY(QVariantMap machinePromptGeometry READ machinePromptGeometry NOTIFY machinePromptChanged)
    Q_PROPERTY(QVariantMap peekState READ peekState NOTIFY peekChanged)
    Q_PROPERTY(QVariantMap peekGeometry READ peekGeometry NOTIFY peekChanged)
    Q_PROPERTY(QVariantMap paletteState READ paletteState NOTIFY paletteChanged)
    Q_PROPERTY(QVariantMap paletteGeometry READ paletteGeometry NOTIFY paletteChanged)
    Q_PROPERTY(QVariantMap suggestionState READ suggestionState NOTIFY paletteChanged)
    Q_PROPERTY(QVariantMap suggestionGeometry READ suggestionGeometry NOTIFY paletteChanged)
    Q_PROPERTY(QVariantMap pathPickerState READ pathPickerState NOTIFY pathPickerChanged)
    Q_PROPERTY(QVariantMap workspaceFormState READ workspaceFormState NOTIFY workspaceFormChanged)
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

    Q_INVOKABLE void editMachineResult(const QVariantMap& choice, MachineEditAction action);
    Q_INVOKABLE void searchMachinePrompt(const QString& text);
    Q_INVOKABLE void submitMachinePrompt(const QString& revision);
    Q_INVOKABLE void reportMachinePromptLimit(qulonglong requested_bytes);
    [[nodiscard]] QVariantMap machinePromptState() const;
    [[nodiscard]] QVariantMap machinePromptGeometry() const;
    Q_INVOKABLE void peekActivity(const QString& identity);
    Q_INVOKABLE void toggleMachineList();
    Q_INVOKABLE void fitSidebar();
    Q_INVOKABLE void searchPeek(const QString& text);
    Q_INVOKABLE void submitPeek(const QString& revision);
    Q_INVOKABLE void reportPeekLimit(qulonglong requested_bytes);
    [[nodiscard]] QVariantMap peekState() const;
    [[nodiscard]] QVariantMap peekGeometry() const;

    using Dialog = Store::Dialog;

    explicit Application(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~Application() override;
    Application(const Application&) = delete;
    Application& operator=(const Application&) = delete;
    Application(Application&&) = delete;
    Application& operator=(Application&&) = delete;

    [[nodiscard]] AttachmentShelf* attachments() noexcept;
    [[nodiscard]] QVariantMap attachmentGeometry() const;
    [[nodiscard]] QVariantMap attachmentModalGeometry() const;
    void attachmentKey(std::uint64_t pane_id, const TerminalKey& key);
    bool interceptAttachmentKey(QKeyEvent& event);
    void open(const QString& endpoint);
    void openMachines(const QString& path);
    void loadConfiguration(const QString& path, const QString& profile, const QString& theme, const QString& trust_path = {});
    void configureLaunch(const QString& directory, const QStringList& arguments, bool restore);
    void configureRemoteLaunch(const QString& destination, const QStringList& arguments);
    void setWindow(QQuickWindow& window);
    bool eventFilter(QObject* watched, QEvent* event) override;
    [[nodiscard]] Pane<Memory>* pane(std::uint64_t identity) const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] ResolvedFont resolveFont(qreal scale);
    [[nodiscard]] ViewVersion viewVersion() const noexcept;
    [[nodiscard]] Qt::KeyboardModifiers pointerModifiers() const noexcept;
    void observePointerModifiers(Qt::KeyboardModifiers modifiers);
    void registerTerminal(TerminalItem& terminal);
    void unregisterTerminal(TerminalItem& terminal);
    [[nodiscard]] const NotificationCenter& notifications() const noexcept;
    [[nodiscard]] QString notificationIdentity(NotificationId identity) const;
    [[nodiscard]] bool notificationTargetVisible(NotificationTarget target) const noexcept;
    [[nodiscard]] DisplayMetrics displayMetrics(qreal density) const;
    [[nodiscard]] Rect notificationHost(const DisplayMetrics& display) const;
    void publishNotification(NotificationInput input);
    void soundPlaybackFinished(std::optional<CommandFailure> failure);
    Q_INVOKABLE void dismissNotification(const QString& identity);
    Q_INVOKABLE void activateNotification(const QString& identity);
    Q_INVOKABLE void retireNotificationFocus(const QString& identity, QQuickItem* retiring_owner = nullptr);
    [[nodiscard]] PointerDispatcher& pointerDispatcher() noexcept;
    [[nodiscard]] std::shared_ptr<const LinkHit> shareLinkHit(const LinkHit& hit);

    Q_INVOKABLE void execute(Action action, const QString& target = {});
    Q_INVOKABLE void submitDialog(const QVariantMap& input);
    Q_INVOKABLE void toggleCopySearchScope();
    // The scrollback searched for `text` as it is typed, from where the search began.
    Q_INVOKABLE void searchScrollback(const QString& text);
    Q_INVOKABLE void stepScrollbackMatch(bool forward);
    Q_INVOKABLE void finishScrollbackSearch();
    [[nodiscard]] QVariantMap copySearchState() const;
    [[nodiscard]] QString copySearchScope() const;
    [[nodiscard]] bool copySearchScopes() const;
    [[nodiscard]] static int controlModifier();
    [[nodiscard]] static int superModifier();
    Q_INVOKABLE void registerTabStrip(QQuickItem* strip);
    Q_INVOKABLE void selectCapturedTab();
    Q_INVOKABLE void setSidebarWidth(qreal width);
    Q_INVOKABLE void searchPalette(const QString& text);
    Q_INVOKABLE void searchPaths(const QString& text);
    Q_INVOKABLE void reportPathQueryLimit(qulonglong requested_bytes);
    Q_INVOKABLE void movePathSelection(int delta);
    // The paths from `first` on, at most `count`, cut to `columns` cells, for the prompt line's rows.
    Q_INVOKABLE QVariantList pathPickerRows(int columns, int first, int count) const;
    Q_INVOKABLE void descendPath();
    Q_INVOKABLE void ascendPath();
    Q_INVOKABLE void insertPath(bool absolute);
    Q_INVOKABLE void activatePath(const QVariantMap& choice);
    Q_INVOKABLE void editWorkspaceDirectory(const QString& text);
    Q_INVOKABLE void moveWorkspaceDirectory(int delta);
    Q_INVOKABLE QString acceptWorkspaceDirectory();
    Q_INVOKABLE QString chooseWorkspaceDirectory(int index);
    Q_INVOKABLE void reportPaletteQueryLimit(qulonglong requested_bytes);
    Q_INVOKABLE void movePalette(int delta);
    Q_INVOKABLE void setPaletteMode(int mode);
    Q_INVOKABLE void usePaletteResult(const QVariantMap& choice);
    Q_INVOKABLE void submitSuggestion(const QString& revision);
    Q_INVOKABLE void resizeDivider(int index, qreal x, qreal y, bool commit);

    bool input(std::uint64_t pane_id, const QByteArray& bytes, PaneInputSource source = PaneInputSource::keyboard);
    void paste(std::uint64_t pane_id, const QString& text);
    // telar's command editor: who has the pane's keyboard, and the keys and text it takes.
    [[nodiscard]] prompt::Surface promptSurface(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool editsPrompt(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] bool hidesTerminalCursor(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] const prompt::Line* promptLine(std::uint64_t pane_id) const noexcept;
    [[nodiscard]] std::string_view promptSuggestion(std::uint64_t pane_id) const noexcept;
    // Whether the pane's shell runs `word`; asks the runtime once and answers pending until then.
    [[nodiscard]] CommandPresence commandPresence(std::uint64_t pane_id, std::string_view word);
    // Shows the pane's scrollback from `row`, counted from its top.
    void scrollPaneToRow(std::uint64_t pane_id, std::uint32_t row);
    // The command block selected in the pane, by index among its blocks, and selecting one, or
    // none to go back to the live end.
    [[nodiscard]] std::optional<std::size_t> selectedBlock(std::uint64_t pane_id) const noexcept;
    void selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index);
    // False hands the key back to the terminal.
    bool promptKey(std::uint64_t pane_id, const prompt::KeyPress& key);
    // While the pane shows a document, its scroll keys move the document; every other key, as
    // q or Ctrl-C, reaches the program that shows it.
    bool documentKey(std::uint64_t pane_id, const QKeyEvent& event);
    // The view measured an inline document in `rows` rows of its own: the pane makes room for it.
    Q_INVOKABLE void measureInlineDocument(const QString& pane_id, qulonglong id, int rows);
    bool promptText(std::uint64_t pane_id, const QString& text);
    void resize(std::uint64_t pane_id, TerminalSize size);
    void scroll(PaneScrollDelta delta);
    bool handleBindingKey(QKeyEvent& event, QQuickItem& recipient, bool captures = false);
    void interruptBindings();
    [[nodiscard]] bool copyModeActive() const noexcept;
    [[nodiscard]] const std::optional<CopyState>& copyState() const noexcept;
    bool handleCopyKey(std::uint64_t pane_id, const QKeyEvent& event);
    bool beginSelection(std::uint64_t pane_id, CopyPoint local);
    bool handleCopyPointer(const CopyPointerInput& input);
    void copySelection(std::uint64_t pane_id);
    bool openLink(const LinkTarget& target, std::optional<std::uint64_t> source_id = {});
    void linkOpeningFinished(MachineClientKey source, std::optional<LinkOpeningFailure> failure);
    void pluginWorkerFinished(std::uint64_t execution, const PluginInvocation& invocation, const PluginWorkerResult& result);

    WorkspacesController* workspaces() noexcept {
      return &workspaces_;
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

    HistoryController* history() noexcept {
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
    [[nodiscard]] QVariantMap workspaceFormState() const;
    [[nodiscard]] QVariantMap pathPickerGeometry() const;
    [[nodiscard]] QVariantMap sidebarGeometry() const;
    [[nodiscard]] QVariantMap machineContext() const;
    [[nodiscard]] bool machineListCollapsed() const noexcept;
    [[nodiscard]] int machineCount() const noexcept;
    [[nodiscard]] SidebarMachines sidebarMachines() const noexcept;
    [[nodiscard]] bool sidebarVisible() const;
    [[nodiscard]] qreal sidebarWidth() const;
    [[nodiscard]] bool workspaceListCollapsed() const;
    [[nodiscard]] qreal windowControls() const;
    [[nodiscard]] QString title() const;
    [[nodiscard]] QVariantMap statusMode() const;
    [[nodiscard]] QVariantMap hostMetrics() const;
    [[nodiscard]] QVariantMap componentBars() const;
    [[nodiscard]] QVariantMap componentPanel() const;
    Q_INVOKABLE void activateComponent(int source, int node, const QString& generation, const QString& revision, const QPointF& anchor);
    // A click on a mod element: runs its action, URL or Lua function.
    Q_INVOKABLE void activateElement(const QString& slot, const QString& key, const QString& revision, int element);
    [[nodiscard]] QVariantMap elementBars() const;
    Q_INVOKABLE void closeComponentPanel();
    Q_INVOKABLE void refreshComponentPanel();
    [[nodiscard]] QVariantMap componentPick() const;
    Q_INVOKABLE void closeComponentPick();
    Q_INVOKABLE void filterComponentPick(const QString& query);
    Q_INVOKABLE void chooseComponentPick(int row, const QString& identity);
    [[nodiscard]] bool prefixPending() const noexcept;
    [[nodiscard]] QString error() const;
    [[nodiscard]] QString tlsBadgeColor() const;
    Q_INVOKABLE void dismissDiagnostic();
    [[nodiscard]] bool connected() const;
    [[nodiscard]] Dialog dialog() const noexcept;
    [[nodiscard]] Dialog lineSearch() const noexcept;
    [[nodiscard]] QString lineSearchPane() const;

  signals:
    void prefixChanged();
    void paletteChanged();
    void pathPickerChanged();
    void workspaceFormChanged();
    void pathPickerGeometryChanged();
    void titleChanged();
    // The error, the TLS proxy badge or whether the runtime is connected moved.
    void diagnosticChanged();
    void copyModeChanged();
    // The attachment shelf's region or the attachment modal's layout moved.
    void attachmentGeometryChanged();
    void elementBarsChanged();
    // Each refresh() of what the window shows from the active session, for the C++ views that
    // compare what they read on their own. No property notifies with it.
    void refreshed();
    void statusModeChanged();
    void hostMetricsChanged();
    void componentsChanged();
    void pickChanged();
    // A configuration was loaded or the theme changed: fonts, colors, keymap and mods.
    void configurationChanged();
    // The window was resized, or the sidebar shown, hidden, resized or its workspace list folded.
    void windowGeometryChanged();
    void runtimeLinkChanged();
    void sidebarGeometryChanged();
    void dialogChanged();
    void copySearchChanged();
    void terminalChanged(qulonglong pane_id);
    void promptChanged(qulonglong pane_id);
    // The document a pane shows natively appeared, changed or went away.
    void documentChanged(qulonglong pane_id);
    void documentScroll(qulonglong pane_id, const QString& action);
    void pointerModifiersChanged();
    void inputReleasing(qulonglong pane_id);
    void notification(const QString& message);
    void notificationsChanged();
    void machineChanged();
    void machinesChanged();
    void machinePromptChanged();
    void peekChanged();
    void machineLaunchFailed(const QString& error);

  private:
    friend struct test::HistoryPresentation;
    friend struct test::FramePacing;
    friend struct test::ComponentActions;
    friend class KeyBindings;
    friend class PointerDispatcher;
    friend class TerminalItem;
    template <typename Host, Allocator Memory, typename Source>
    friend class PickController;

    [[nodiscard]] BindingContext bindingContext() const;
    [[nodiscard]] std::optional<BindingRepeat> bindingRepeat(BindingAction action) const;
    // `resolved` describes actions a Lua render or callback returned; configured bindings need none.
    bool runBinding(BindingAction action, const ConfigurationSource::Actions* resolved = nullptr);
    void executeBinding(BindingAction action, const ConfigurationSource::Actions* resolved = nullptr);
    void luaBindingFinished(KeyBindings::Hold hold, bool stale, const QString& error, const std::function<void()>& apply);
    void applyEffects(const ResolvedEffects<ApplicationAllocator>& effects);
    void executeNamedAction(const NamedActionDescription& named);
    void executeCommandTab(BindingAction action, const ConfigurationSource::Actions* resolved);
    void executeNotificationBinding(BindingAction action, const ConfigurationSource::Actions* resolved);
    void initializeComponents();
    void resetComponents();
    void tickComponents();
    void projectComponents();
    void projectComponentSource(std::size_t index, bool panel);
    void armComponents();
    void renderComponentSource(std::size_t index, bool panel);
    void applyComponentRender(std::size_t index, bool panel, const components::Context& context, bool truncated = false);
    void componentCommandFinished(const ComponentCommandOwner& owner, SurfaceCommandResult result);
    [[nodiscard]] const ComponentSlotState::Bar* componentBar(std::size_t index) const;
    [[nodiscard]] bool componentActionsLive(const ConfigurationSource::Actions& actions) const;
    void initializeElements();
    // The mod content a record carries for its slots, keyed by slot name.
    void refreshElementBars();
    void activateComponentAction(std::optional<BindingAction> action, std::string_view url, const QString& identity, const QPointF& anchor, const ConfigurationSource::Actions& resolved);
    void toggleComponentPanel(std::size_t index);
    [[nodiscard]] components::Context componentContext() const;
    [[nodiscard]] bool componentCommandCurrent(std::uint64_t generation, MachineClientKey source, std::uint64_t runtime) const;
    void initializePicks();
    void openComponentPick(std::size_t index);
    void restoreComponentPickFocus();
    [[nodiscard]] PickOwner pickOwner() const;
    [[nodiscard]] bool pickOwnerCurrent(const PickOwner& owner) const;
    [[nodiscard]] components::Context pickContext() const;
    void pickCommitted();
    void pickFailed(const QString& message);
    void startPlugin(const PluginInvocation& invocation);
    void applyPluginEffects(const PluginEffects& effects);
    void applyExpression(const InputExpression& expression);
    void scrollBinding(ScrollDirection direction);
    [[nodiscard]] QString bindingShortcut(BindingActionKind action) const;
    using PaletteTarget = std::variant<NavigationTarget, Action, MachinePickerTarget>;
    static constexpr std::size_t palette_capacity = WorkspaceReplica<Memory>::maximum_workspaces + GuiSession::maximum_workspace_tabs + AgentReplica<Memory>::capacity;
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
    [[nodiscard]] std::optional<MachinePickerTarget> chosenMachine(const QVariantMap& choice) const;
    [[nodiscard]] std::size_t machinePromptLimit() const noexcept;
    void initializeMachineProfiles();
    void applyMachineProfiles();
    void openRequestedMachine();
    void reconcileMachines();
    void reconcileMachine(const MachineProfile& profile);
    void admitMachine(Machines::Slot slot);
    void retireMachine(Machines::Slot slot, MachineRetirement reason);
    static void discoveredMachine(MachineClient& client, const RemoteDiscovery& discovery);
    void initializeMachines();
    void configureClients();
    void setClientsDisplayRefresh(std::uint16_t fps);
    [[nodiscard]] MachineClient& createClient(Machines::Slot slot);
    [[nodiscard]] MachineClient& clientAt(Machines::Slot slot) const noexcept;
    void selectMachine(MachineToken target);
    void releaseMachineInput();
    void forgetMachineView();
    void summarizeMachine(MachineClientKey key);
    void connectMachine(Machines::Slot slot);
    [[nodiscard]] MachineClient* findClient(MachineClientKey key) const noexcept;
    [[nodiscard]] GuiSession& session() noexcept;
    [[nodiscard]] const GuiSession& session() const noexcept;
    [[nodiscard]] RuntimeConnection& connection() noexcept;
    [[nodiscard]] const RuntimeConnection& connection() const noexcept;
    void runtimeDisconnected(MachineClient& client);
    void cancelCurrentInteraction();
    void showPalette(PaletteMode mode);
    void refreshPalette();
    bool restorePaletteParent();
    bool updatePaletteResults();
    void collectPaletteNavigation(PaletteMatches& matches, std::string_view query) const;
    [[nodiscard]] QVariantMap paletteRecord(const PaletteTarget& target, bool queried) const;
    bool navigatePaletteTarget(const NavigationTarget& target);
    void showPathPicker();
    void refreshPathPicker();
    [[nodiscard]] PathPickerPlacement pathPlacement() const;
    QString path_query_;
    std::size_t path_selection_ = 0;

    // The new workspace form's folder suggestions. Listings run one at a time
    // on a worker; the query typed meanwhile starts once the running one lands.
    struct WorkspaceForm {
      QString wanted;
      QString listing;
      QString landed;
      DirectoryCompletion completion;
      std::size_t selection = 0;
      bool confirm_create = false;
    };

    void resetWorkspaceForm();
    void listWorkspaceDirectory();
    void landWorkspaceDirectory();
    bool submitWorkspace(const QVariantMap& input);
    [[nodiscard]] bool workspaceListingCurrent() const;
    [[nodiscard]] QString expandWorkspaceDirectory(const QString& text) const;
    WorkspaceForm workspace_form_;
    QFutureWatcher<DirectoryCompletion> workspace_listing_;
    static constexpr Viewport default_viewport{.width = 1200, .height = 800, .scale = 1};

    struct PresentedPane {
      TerminalPreparation frame;
      QPointer<TerminalItem> terminal;
    };

    struct PresentedFrame {
      std::uint64_t machine_view = 0;
      std::array<PresentedPane, PaneLayout::maximum_panes> panes;
      std::size_t pane_count = 0;
      std::uint64_t preparation_ns = 0;
      TabDropSurface tabs;
      HistoryController::Frame history;
    };

    // The render thread prepares each frame into the slot after the last one while the GUI
    // thread presents, and posts the slot and the sequence it prepared there. A slot prepared
    // again before its frame was presented holds a newer frame, whose own post presents it.
    struct PresentedFrames {
      std::array<PresentedFrame, 2> prepared;
      std::array<std::uint64_t, 2> sequences{};
      std::uint64_t sequence = 0;
      std::size_t current = 0;

      PresentedFrame& next() noexcept {
        current = ++sequence % prepared.size();
        sequences[current] = sequence;
        return prepared[current];
      }
    };

    // Answers the commands of the active machine's client. A configuration reply views the
    // application's buffers, region `a`, until the client encodes it.
    struct HostCommands final : ClientCommandHandler {
      HostCommands(tbc::view<Application&, tbc::lt::a> owner, bool is_active) noexcept
          : application(owner),
            active(is_active) {}

      void operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const override;

      tbc::view<Application&, tbc::lt::a> application;
      bool active = false;
    };

    void consume(MachineClient& client, QByteArrayView payload);
    [[nodiscard]] static bool answerConfiguration(tbc::view<Application&, tbc::lt::a> application, const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply);
    void executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply);
    void synchronizeFontMetrics();
    void synchronizeWorkbenchGeometry();
    void synchronizeDisplay();
    void synchronizeScreen();
    void synchronizeWindowSize();
    bool updateViewport(qreal width, qreal height);
    void observeFrames(QQuickWindow& window);
    void refresh();
    // Drops the theme and font QML reads and notifies a new configuration.
    void publishConfiguration();
    // Notifies the title, diagnostic and copy mode properties whose value moved since they were
    // last published.
    void publishStatus();
    // Notifies the attachment geometries when what they are measured from moved.
    void publishAttachmentGeometry();
    void fitSidebarWhenReady();
    [[nodiscard]] float sidebarNaturalWidth() const;
    void selectActivity(const QString& identity, bool peek = false);
    void settleActivity();
    [[nodiscard]] bool peekOriginValid() const;
    void refreshPeek();
    void openActivityPeek(const MachineActivityTarget& target, const QString& identity, std::uint64_t pointer_revision);
    void presentChange(Change change);
    void initializeAttachments();
    void attachmentShelfChanged();
    void reconcileAttachmentFrame(std::uint64_t pane_id);
    void dismissAttachment(std::uint64_t identity);
    void synchronizeAttachments();
    void refreshPanes();
    [[nodiscard]] HistoryModalMetrics historyMetrics() const;
    [[nodiscard]] TabDropSurface tabDropSurface() const;
    void synchronizeTabStrip();
    void showDialog(Dialog kind);
    void fail(const std::exception& error);
    void publishCopyChange(std::uint64_t previous_pane);
    void leaveKeyboardCopyMode();
    void openCopyLink(std::uint64_t pane_id, CellPosition point);
    [[nodiscard]] QString suggestionRevision() const;
    void present(const PresentedFrame& frame);
    void prepareFrame(PresentedFrame& frame);
    void prepareTerminalFrames(PresentedFrame& frame);
    void recordPreparedFrame(const PresentedFrame& frame);
    [[nodiscard]] TerminalItem* visibleTerminal(std::uint64_t pane_id) const;
    [[nodiscard]] std::size_t collectPacingPanes(std::span<FramePacer::Pane, PaneLayout::maximum_panes> panes) const;
    void reconsiderFrame();
    void requestTerminalFrame();
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
    [[nodiscard]] std::optional<NotificationId> resolveNotification(const QString& identity) const;
    bool executeNavigation(Action action, const QString& target);
    bool executePane(Action action, std::uint64_t identity);
    void executeWindowAction(Action action);

    // Text the line's editor took from outside the keyboard reaches its view.
    void publishPromptWrite() {
      if (const auto pane_id = session().takePromptWrite()) {
        emit promptChanged(*pane_id);
      }
    }

    // Runs a user's mutation of the session, then commits it to the store, whose interacted()
    // publishes what the mutation wrote and refreshes the window.
    template <std::invocable Mutation>
    void applyInteraction(Mutation mutate) {
      store_.begin();
      try {
        mutate();
      } catch (const std::exception& error) {
        interactionFailed(error);
        return;
      }

      store_.commit();
    }

    void interacted();
    void interactionFailed(const std::exception& error);
    // Brings every projection that reads the store up to date, in the order they depend on each
    // other; each one rebuilds only what moved since its last pass.
    void synchronize();

    ApplicationAllocator& memory_;
    Store store_;
    HistoryController history_;

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

    std::optional<PendingActivity> pending_activity_;
    std::optional<PeekOrigin> peek_origin_;
    QString peek_editor_;
    std::optional<MachineClientKey> sound_owner_;
    ConfigurationSource configuration_source_;
    // The theme and font QML reads, built on first read after each configurationChanged.
    mutable std::optional<QVariantMap> colors_;
    mutable std::optional<QVariantMap> font_;
    tbc::view<PickController<Application, ApplicationAllocator, ConfigurationSource>, tbc::lt::self> pick_controller_;
    QPointer<QQuickItem> component_pick_return_focus_;
    ComponentSurfaceState component_surfaces_;
    tbc::view<ElementSlots, tbc::lt::self> element_slots_{configuration_source_, [this] {
                                                            return componentContext();
                                                          },
        this};
    QVariantMap element_bars_;
    QTimer component_timer_;
    tbc::view<SurfaceCommand, tbc::lt::self> component_command_;
    std::optional<ComponentCommandOwner> component_command_owner_;
    std::uint64_t next_component_revision_ = 0;
    std::optional<QPointF> component_action_anchor_;
    tbc::view<PluginWorker<Application>, tbc::lt::self> plugin_worker_;

    struct PluginOwner {
      MachineClientKey source;
      std::uint64_t runtime_generation = 0;
      std::uint64_t execution = 0;
    };

    std::optional<PluginOwner> plugin_owner_;
    std::uint64_t next_plugin_execution_ = 1;
    MachineProfilesSource machine_profiles_;
    AttachmentShelf attachments_;
    bool attachment_modal_active_ = false;
    std::optional<MachinePrompt> machine_prompt_;
    std::optional<RemoteLaunch> remote_launch_;
    QTimer machine_retry_;
    QString machine_control_endpoint_;
    bool prepare_machine_directory_ = false;
    SidebarMachines sidebar_machines_{};
    bool machine_list_collapsed_ = false;
    bool sidebar_fit_pending_ = true;
    bool restore_layout_ = true;
    std::optional<WindowFramePacer<>> frame_pacer_;
    tbc::view<KeyBindings, tbc::lt::self> key_bindings_;
    tbc::view<PointerDispatcher, tbc::lt::self> pointer_dispatcher_;
    tbc::view<ExternalLinkOpener<ApplicationLinkHost, Application, MachineClientKey>, tbc::lt::self> link_opener_;
    tbc::view<SoundPlayer<ApplicationSoundHost, Application>, tbc::lt::self> sound_player_;
    SystemNotifier<ApplicationNotificationHost, ApplicationAllocator> system_notifier_;
    WorkspacesController workspaces_;
    TabsController tabs_;
    PanesController panes_;
    ActivityController activity_;
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
    QTimer notification_timer_;
    QTimer graphics_resume_timer_;
    QString error_;

    // What the status properties last published, so publishStatus() notifies only what moved.
    struct PublishedStatus {
      QString title;
      QString error;
      QString tls_badge_color;
      bool connected = false;
      bool copy_mode = false;
    };

    // What the attachment geometries are measured from.
    struct AttachmentInputs {
      WorkbenchGeometry host;
      Rect terminal;
      CellRectangle reserved;
      double density = 1;
      bool shelf = false;

      bool operator==(const AttachmentInputs&) const = default;
    };

    PublishedStatus published_status_;
    std::optional<AttachmentInputs> published_attachments_;
    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
    QMetaObject::Connection screen_refresh_connection_;
    Viewport viewport_ = default_viewport;
    CellMetrics cell_metrics_;
    TerminalGrid terminal_grid_;
    TabDropSurface presented_tabs_;
    QPointer<QQuickItem> tab_strip_;
    QHash<std::uint64_t, QPointer<TerminalItem>> terminals_;
    QByteArray hostname_;
    Qt::KeyboardModifiers pointer_modifiers_;
  };

}
