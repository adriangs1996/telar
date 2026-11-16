#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application.hpp"
#include "application/dependencies.hpp"
#include "application_effects.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "input/wheel_accumulator.hpp"
#include "launch_arguments.hpp"
#include "platform/window.hpp"
#include "projection.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/protocol/clients.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/graphics/limits.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "ui/chrome/metrics_projection.hpp"
#include "ui/chrome/mode_projection.hpp"
#include "ui/fonts/terminal_font.hpp"
#include "ui/fonts/window_font_catalog.hpp"
#include "ui/history/history_filters_layout.hpp"
#include "ui/history/history_footer_layout.hpp"
#include "ui/history/history_inspection_layout.hpp"
#include "ui/machines/machine_client.hpp"
#include "ui/panes/pane_projection.hpp"
#include "ui/scene/window_animation_clock.hpp"
#include "ui/terminal/terminal_item.hpp"
#include "ui/terminal/window_images.hpp"
#include "ui/workspaces/project_projection.hpp"
#include "utf16_encoding.hpp"
#include <QAbstractItemModel>
#include <QClipboard>
#include <QCryptographicHash>
#include <QDir>
#include <QEvent>
#include <QFutureWatcher>
#include <QGuiApplication>
#include <QPointer>
#include <QQuickItem>
#include <QScreen>
#include <QStringView>
#include <QStyleHints>
#include <QVariant>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlist.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <atomic>
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
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>
#include <vector>

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "platform/window.hpp"
#include "utf16_encoding.hpp"

import telar.gui.layout.geometry;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.gui.config.gui_query;
import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.presentation.history_pointer;
import telar.gui.links.cell_links;
import telar.gui.platform.login_shell;
import telar.gui.machines.picker;
import telar.gui.palette.navigation_label;
import telar.gui.paths.label;
import telar.gui.platform.awake_clock;
import telar.gui.presentation.frame_pacer;
import telar.gui.presentation.history_inspection;
import telar.base.text.utf8;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  namespace {

    auto parseLocation(const QString& key) -> WorkspaceLocation {
      return {
          .kind = key.startsWith(QLatin1StringView("worktree:")) ? WorkspaceLocation::Kind::worktree : WorkspaceLocation::Kind::workspace,
          .id = key.section(QLatin1Char(':'), 1).toULongLong(),
      };
    }

    auto paneDirection(Application::Action action) noexcept -> PaneDirection {
      using Action = Application::Action;

      switch (action) {
      case Action::focus_left:
      case Action::resize_left:
        return PaneDirection::left;
      case Action::focus_right:
      case Action::resize_right:
        return PaneDirection::right;
      case Action::focus_up:
      case Action::resize_up:
        return PaneDirection::up;
      default:
        return PaneDirection::down;
      }
    }

    auto dialogFor(Application::Action action) -> Application::Dialog {
      using Action = Application::Action;
      using Dialog = Application::Dialog;

      switch (action) {
      case Action::palette:
        return Dialog::palette;
      case Action::new_workspace:
        return Dialog::new_workspace;
      case Action::rename_tab:
        return Dialog::rename_tab;
      case Action::rename_workspace:
        return Dialog::rename_workspace;
      default:
        return Dialog::none;
      }
    }

  }

  Application::Application(ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        memory_(memory),
        history_(store_),
        activity_targets_(AllocatorRef<ActivityRowTarget, ApplicationAllocator>{memory}),
        configuration_source_(memory),
        pick_controller_(*this, memory, configuration_source_),
        plugin_worker_(memory, *this),
        machine_profiles_(memory),
        attachments_(memory),
        key_bindings_(*this),
        pointer_dispatcher_(*this),
        link_opener_(*this),
        sound_player_(*this),
        system_notifier_(memory),
        workspaces_(store_),
        tabs_(store_, element_slots_),
        panes_(store_, element_slots_),
        hostname_(platform::hostName()) {
    initializeMachines();
    initializeMachineProfiles();
    initializeAttachments();
    initializeComponents();
    initializeElements();
    initializePicks();
    key_bindings_.configure(configuration_source_.input(), configuration_source_.keymap());

    connect(this, &Application::configurationChanged, this, &Application::windowGeometryChanged);
    connect(this, &Application::copyModeChanged, this, &Application::statusModeChanged);
    // The prefix mode lists the keymap's hints.
    connect(this, &Application::configurationChanged, this, &Application::statusModeChanged);
    connect(this, &Application::configurationChanged, this, &Application::paletteChanged);
    connect(&store_, &Store::interacted, this, &Application::interacted);
    connect(&store_, &Store::changed, this, &Application::synchronize);
    connect(&store_, &Store::interacting, this, [this] {
      pending_activity_.reset();
    });
    connect(this, &Application::windowGeometryChanged, this, &Application::paletteChanged);
    connect(this, &Application::windowGeometryChanged, this, &Application::pathPickerGeometryChanged);
    connect(this, &Application::pathPickerChanged, this, &Application::pathPickerGeometryChanged);
    connect(&workspace_listing_, &QFutureWatcher<DirectoryCompletion>::finished, this, &Application::landWorkspaceDirectory);
    connect(this, &Application::prefixChanged, this, &Application::statusModeChanged);
    connect(this, &Application::windowGeometryChanged, this, &Application::synchronizeWorkbenchGeometry);
    connect(this, &Application::windowGeometryChanged, this, &Application::sidebarGeometryChanged);
    connect(this, &Application::windowGeometryChanged, this, [this] {
      history_.setMetrics(historyMetrics());
    });
    connect(&history_, &HistoryController::submitted, this, [this] {
      error_.clear();
    });
    connect(&history_, &HistoryController::closeRequested, this, [this] {
      showDialog(Dialog::none);
    });
    connect(&history_, &HistoryController::failed, this, [this](const QString& message) {
      error_ = message;
      publishStatus();
    });
    connect(this, &Application::windowGeometryChanged, this, &Application::refreshPeek);
    connect(this, &Application::windowGeometryChanged, this, &Application::runtimeLinkChanged);
    connect(this, &Application::machineChanged, this, &Application::runtimeLinkChanged);
    connect(this, &Application::machineChanged, this, &Application::hostMetricsChanged);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsInserted, this, &Application::sidebarGeometryChanged);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsRemoved, this, &Application::sidebarGeometryChanged);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsMoved, this, &Application::sidebarGeometryChanged);
    connect(workspaces_.rows(), &QAbstractItemModel::dataChanged, this, &Application::sidebarGeometryChanged);

    const platform::login_shell::Command shell;
    const auto directory = QDir::currentPath().toUtf8();

    session().setLaunch(Launch{
        .cwd = {
            directory.constData(),
            static_cast<std::size_t>(directory.size()),
        },
        .arguments = shell.arguments(),
    });

    refresh_timer_.setSingleShot(true);
    initializeNotifications();
    initializeGraphicsRecovery();

    connect(&configuration_source_, &ConfigurationSource::changed, this, [this] {
      error_.clear();
      key_bindings_.configure(configuration_source_.input(), configuration_source_.keymap());
      configureClients();
      synchronizeFontMetrics();
      // A reload sets the sidebar back to its configured width, so an automatic one fits again.
      sidebar_fit_pending_ = true;
      fitSidebarWhenReady();

      publishConfiguration();
      history_.setMetrics(historyMetrics());
      configureWindow();
      refresh();
    });

    connect(&configuration_source_, &ConfigurationSource::failed, this, [this] {
      error_ = configuration_source_.error();
      publishStatus();
    });

    connect(&configuration_source_, &ConfigurationSource::themeChanged, this, [this] {
      for (auto& client : store_.clients()) {
        if (client) {
          (*client)->session.setTheme(configuration_source_.configuration().theme);
        }
      }

      publishConfiguration();
      refresh();
    });

    connect(&refresh_timer_, &QTimer::timeout, this, &Application::refresh);
    connect(this, &Application::machinesChanged, this, [this] {
      const auto machines = sidebarMachines();
      if (machines != sidebar_machines_) {
        sidebar_machines_ = machines;
        emit sidebarGeometryChanged();
      }

      if (!refresh_timer_.isActive()) {
        refresh_timer_.start();
      }
    });

    synchronizeWorkbenchGeometry();
  }

  void Application::runtimeDisconnected(MachineClient& client) {
    if (pending_activity_ && pending_activity_->target.source == client.key) {
      pending_activity_.reset();
    }

    client.session.disconnected();
    static_cast<void>(client.session.settlePresentation());
    client.phase = client.connection.link().phase;
    client.needs_setup = client.connection.link().setup_repairs;
    summarizeMachine(client.key);
    if (client.key.machine.slot != store_.machines().active()) {
      return;
    }

    if (store_.dialog().kind == Dialog::palette) {
      emit paletteChanged();
    }

    if (store_.dialog().kind == Dialog::paths || store_.dialog().kind == Dialog::peek) {
      showDialog(Dialog::none);
    }

    scheduleGraphicsRecovery();
    emit hostMetricsChanged();
    refresh_timer_.start();
  }

  void Application::loadConfiguration(const QString& path, const QString& profile, const QString& theme, const QString& trust_path) {
    configuration_source_.open({.path = path, .profile = profile, .theme = theme, .trust_path = trust_path});
  }

  void Application::configureLaunch(const QString& directory, const QStringList& arguments, bool restore) {
    const auto cwd = QDir{directory.isEmpty() ? QDir::currentPath() : directory}.absolutePath().toUtf8();
    const platform::login_shell::Command shell;
    const LaunchArguments prepared{arguments};
    const auto command = arguments.isEmpty() ? shell.arguments() : prepared.argv();

    session().setLaunch(Launch{.cwd = {cwd.constData(), static_cast<std::size_t>(cwd.size())}, .arguments = command});
    restore_layout_ = restore;
    session().setRestoreLayout(restore);
  }

  Application::~Application() {
    if (window_ != nullptr) {
      window_->removeEventFilter(this);
      window_->disconnect(this);
    }

    frame_pacer_.reset();
    QObject::disconnect(screen_refresh_connection_);
    for (auto& client : store_.clients()) {
      if (client) {
        (*client)->connection.disconnect(this);
        (*client)->connection.close();
      }
    }
  }

  void Application::open(const QString& endpoint) {
    auto& client = clientAt(Machines::local_slot);
    const auto path = endpoint.toUtf8();

    client.identity_lease.emplace(std::string_view{path.constData(), static_cast<std::size_t>(path.size())});
    QCryptographicHash hash{QCryptographicHash::Sha256};
    constexpr auto identity_namespace = std::to_array("telar-gui-window-v1");
    const auto canonical_endpoint = client.identity_lease->endpoint();

    hash.addData(QByteArrayView{identity_namespace.data(), static_cast<qsizetype>(identity_namespace.size())});
    hash.addData(QByteArrayView{canonical_endpoint.data(), static_cast<qsizetype>(canonical_endpoint.size())});
    constexpr char separator = '\0';

    hash.addData(QByteArrayView{&separator, 1});
    const auto slot = static_cast<char>(client.identity_lease->slot());

    hash.addData(QByteArrayView{&slot, 1});
    const auto digest = hash.result();
    auto identity_bytes = byteView({digest.constData(), static_cast<std::size_t>(digest.size())}).first(sizeof(std::uint64_t));

    client.identity = u64::decode(identity_bytes) | std::uint64_t{1};
    client.connection.open(endpoint);
  }

  void Application::setWindow(QQuickWindow& window) {
    if (window_ == &window) {
      return;
    }

    if (store_.dialog().kind == Dialog::peek) {
      showDialog(Dialog::none);
    }

    if (window_ != nullptr) {
      window_->removeEventFilter(this);
      window_->disconnect(this);
    }

    // Keep every chrome action reachable, independent of the desktop's text-only Tab policy.
    QGuiApplication::styleHints()->setTabFocusBehavior(Qt::TabFocusAllControls);

    window_ = &window;
    ++window_generation_;
    frame_pacer_.reset();
    frame_pacer_.emplace(window);
    history_.setWindow(&window);
    pointer_dispatcher_.presentHistoryActions({});
    key_bindings_.setWindow(window);
    pointer_dispatcher_.setWindow(window);
    window.installEventFilter(this);
    connect(&window, &QWindow::widthChanged, this, &Application::synchronizeWindowSize);
    connect(&window, &QWindow::heightChanged, this, &Application::synchronizeWindowSize);
    connect(&window, &QWindow::screenChanged, this, &Application::synchronizeScreen);
    connect(&window, &QWindow::windowStateChanged, this, &Application::windowGeometryChanged);
    observeFrames(window);
    synchronizeScreen();
    configureWindow();
  }

  void Application::synchronizeScreen() {
    QObject::disconnect(screen_refresh_connection_);
    if (window_ != nullptr && window_->screen() != nullptr) {
      screen_refresh_connection_ = connect(window_->screen(), &QScreen::refreshRateChanged, this, &Application::synchronizeCadence);
    }

    synchronizeDisplay();
    synchronizeCadence();
  }

  void Application::synchronizeDisplay() {
    try {
      synchronizeFontMetrics();
      if (window_ != nullptr) {
        updateViewport(window_->width(), window_->height());
      }

      emit windowGeometryChanged();
      refreshPanes();
    } catch (const std::exception& error) {
      fail(error);
    }
  }

  bool Application::eventFilter(QObject* watched, QEvent* event) {
    if (watched == window_ && frame_pacer_ && event->type() == QEvent::UpdateRequest) {
      std::array<FramePacer::Pane, PaneLayout::maximum_panes> panes;
      const auto count = collectPacingPanes(panes);

      return frame_pacer_->defer(std::span{panes}.first(count));
    }

    if (watched == window_ && window_ != nullptr && event->type() == QEvent::DevicePixelRatioChange && window_->effectiveDevicePixelRatio() != terminal_grid_.scale) {
      synchronizeDisplay();
    }

    return false;
  }

  void Application::observeFrames(QQuickWindow& window) {
    WindowImages::forWindow(window);
    connect(&window, &QQuickWindow::afterAnimating, this, &Application::prepareImagePlacements);
    const auto generation = window_generation_;
    // Preparation runs while the scene graph synchronizes, with the GUI thread blocked, so it
    // never overlaps a present on the GUI thread.
    const auto frames = std::allocate_shared<PresentedFrames>(AllocatorRef<PresentedFrames, ApplicationAllocator>{memory_});

    connect(&window, &QQuickWindow::beforeSynchronizing, this, [this, frames, generation] {
      if (generation == window_generation_) {
        prepareFrame(frames->next());
      }
    },
        Qt::DirectConnection);
    connect(&window, &QQuickWindow::afterSynchronizing, this, [this, frames, generation] {
      if (generation == window_generation_) {
        auto& frame = frames->prepared[frames->current];

        prepareTerminalFrames(frame);
        recordPreparedFrame(frame);
      }
    },
        Qt::DirectConnection);

    connect(
        &window,
        &QQuickWindow::frameSwapped,
        this,
        [this, frames, generation] {
          const auto slot = frames->current;

          QMetaObject::invokeMethod(
              this,
              [this, frames, slot, sequence = frames->sequences[slot], generation] {
                if (window_ != nullptr && generation == window_generation_ && frames->sequences[slot] == sequence) {
                  present(frames->prepared[slot]);
                }
              },
              Qt::QueuedConnection
          );
        },
        Qt::DirectConnection
    );
  }

  PointerDispatcher& Application::pointerDispatcher() noexcept {
    return pointer_dispatcher_;
  }

  void Application::prepareImagePlacements() {
    if (window_ == nullptr) {
      return;
    }

    std::array<ImagePlacementSource, PaneLayout::maximum_panes> sources;
    std::size_t count = 0;
    const auto* tab = session().activeTab();
    if (tab != nullptr) {
      forEachLeaf(*tab, true, [&](const ClientLayoutPane& leaf) {
        const auto* pane = session().findPane(leaf.pane_id);
        const auto terminal = terminals_.constFind(leaf.pane_id);
        if (pane != nullptr && pane->attached && terminal != terminals_.cend() && *terminal != nullptr && (*terminal)->window() == window_ && (*terminal)->isVisible()) {
          sources[count++] = {.owner = *terminal, .store = &pane->graphics, .cell = (*terminal)->cellSize()};
        }
      });
    }

    if (const auto reach = WindowImages::forWindow(*window_).preparePlacements(std::span{sources}.first(count))) {
      session().reportLimit(*reach);
      refreshNotifications();
    }
  }

  void Application::prepareFrame(PresentedFrame& frame) {
    frame = {};
    frame.machine_view = store_.machineView();
    frame.preparation_ns = platform::AwakeClock::nowNanoseconds();
    frame.tabs = tabDropSurface();
    if (window_ == nullptr) {
      return;
    }

    auto* images = WindowImages::findWindow(*window_);
    if (images != nullptr && !images->empty()) {
      images->beginCatalogSnapshot();
      for (const auto& pane : std::as_const(*this).session().panes()) {
        images->observeCatalog(pane->graphics);
      }
    }

    history_.prepare(frame.history);
  }

  void Application::prepareTerminalFrames(PresentedFrame& frame) {
    if (window_ == nullptr) {
      return;
    }

    const auto* tab = session().activeTab();
    if (tab == nullptr) {
      return;
    }

    forEachLeaf(*tab, true, [&](const ClientLayoutPane& leaf) {
      const auto* pane = session().findPane(leaf.pane_id);
      auto* terminal = pane != nullptr && pane->attached ? visibleTerminal(pane->id) : nullptr;
      if (terminal == nullptr) {
        return;
      }

      const auto& prepared = terminal->prepared_frame_;
      if (prepared.pane.attached && prepared.pane.pane_id == pane->id && prepared.pane.attachment_generation == pane->attachment_generation) {
        frame.panes[frame.pane_count++] = {.frame = prepared, .terminal = terminal};
      }
    });
  }

  TerminalItem* Application::visibleTerminal(std::uint64_t pane_id) const {
    const auto terminal = terminals_.constFind(pane_id);
    if (terminal == terminals_.cend() || *terminal == nullptr || (*terminal)->window() != window_ || !(*terminal)->isVisible() || !(*terminal)->flags().testFlag(QQuickItem::ItemHasContents) || (*terminal)->width() <= 0 || (*terminal)->height() <= 0) {
      return nullptr;
    }

    return *terminal;
  }

  std::size_t Application::collectPacingPanes(std::span<FramePacer::Pane, PaneLayout::maximum_panes> panes) const {
    const auto* tab = session().activeTab();
    if (window_ == nullptr || tab == nullptr) {
      return 0;
    }

    std::size_t count = 0;

    forEachLeaf(*tab, true, [&](const ClientLayoutPane& leaf) {
      if (visibleTerminal(leaf.pane_id) == nullptr) {
        return;
      }

      if (const auto* pane = session().findPane(leaf.pane_id); pane != nullptr && pane->attached) {
        panes[count++] = {.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = true, .attachment_generation = pane->attachment_generation, .graphics_revision = pane->graphics.revision()};
      }
    });

    return count;
  }

  void Application::recordPreparedFrame(const PresentedFrame& frame) {
    if (!frame_pacer_) {
      return;
    }

    std::array<FramePacer::Pane, PaneLayout::maximum_panes> panes;

    for (std::size_t index = 0; index < frame.pane_count; ++index) {
      panes[index] = frame.panes[index].frame.pane;
    }

    frame_pacer_->record(std::span{panes}.first(frame.pane_count), frame.preparation_ns);
  }

  void Application::reconsiderFrame() {
    if (!frame_pacer_ || !frame_pacer_->pending()) {
      return;
    }

    std::array<FramePacer::Pane, PaneLayout::maximum_panes> panes;
    const auto count = collectPacingPanes(panes);

    frame_pacer_->reconsider(std::span{panes}.first(count));
  }

  void Application::requestTerminalFrame() {
    if (!platform::supportsImmediateWindowUpdates()) {
      reconsiderFrame();

      return;
    }

    if (!frame_pacer_) {
      return;
    }

    if (frame_pacer_->pending()) {
      reconsiderFrame();

      return;
    }

    const auto pane_id = session().changedPane();
    const auto* tab = session().activeTab();
    if (tab == nullptr || !tab->layout.contains(pane_id) || (tab->fullscreen && tab->focused_pane != pane_id) || visibleTerminal(pane_id) == nullptr) {
      return;
    }

    if (const auto* pane = session().findPane(pane_id); pane != nullptr && pane->attached && frame_pacer_) {
      frame_pacer_->requestInputFrame({.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = true, .attachment_generation = pane->attachment_generation, .graphics_revision = pane->graphics.revision()});
    }
  }

  void Application::configureFramePacer() {
    if (frame_pacer_ && window_ != nullptr) {
      frame_pacer_->configure(WindowAnimationClock::forWindow(*window_).frameInterval(), std::nullopt);
    }
  }

  void Application::synchronizeCadence() {
    if (window_ == nullptr || window_->screen() == nullptr) {
      return;
    }

    const auto rate = window_->screen()->refreshRate();
    if (std::isfinite(rate) && rate > 0) {
      const auto fps = static_cast<std::uint16_t>(std::clamp(std::round(rate), qreal{Configuration::minimum_fps}, qreal{Configuration::maximum_fps}));

      setClientsDisplayRefresh(fps);
    }

    configureFramePacer();
  }

  void Application::configureWindow() {
    if (window_ == nullptr) {
      return;
    }

    const auto& configuration = session().configuration();

    WindowAnimationClock::forWindow(*window_).setMaximumFrameRate(configuration.max_fps == 0 ? std::nullopt : std::optional{configuration.max_fps});
    configureFramePacer();
    const QPointer<Application> lifetime{this};
    const auto owner = window_;

    WindowFontCatalog::forWindow(*owner).configure(configuration.font);
    if (lifetime.isNull() || owner.isNull() || window_ != owner) {
      return;
    }

    platform::configureWindow(*window_, {.titlebar = configuration.titlebar.value_or(platform::defaultTitlebar()), .navigation_height = displayMetrics(window_->effectiveDevicePixelRatio()).chrome.top_bar / static_cast<float>(window_->effectiveDevicePixelRatio()), .background_opacity = configuration.opacity.minimum(configuration.background_opacity), .background_blur = configuration.background_blur});
    emit windowGeometryChanged();
  }

  void Application::present(const PresentedFrame& frame) {
    if (frame.machine_view != store_.machineView()) {
      return;
    }

    presented_tabs_ = frame.tabs;
    pointer_dispatcher_.presentTabs(presented_tabs_);
    history_.present(frame.history);
    pointer_dispatcher_.presentHistoryActions(history_.presentedActions());

    try {
      for (const auto& pane : std::span{frame.panes}.first(frame.pane_count)) {
        const auto& identity = pane.frame.pane;
        const auto* current = session().findPane(identity.pane_id);
        if (current == nullptr || !current->attached || current->attachment_generation != identity.attachment_generation) {
          continue;
        }

        auto* const terminal = pane.terminal.data();
        if (terminal != nullptr && terminal->application() == this && terminal->paneIdentity() == identity.pane_id) {
          terminal->presentFrame(pane.frame);
        }

        session().presented(identity.pane_id, identity.frame_id);
      }
    } catch (const std::exception& error) {
      fail(error);
    }
  }

  Pane<Memory>* Application::pane(std::uint64_t identity) const noexcept {
    return session().findPane(identity);
  }

  const Configuration& Application::configuration() const noexcept {
    return session().configuration();
  }

  void Application::consume(MachineClient& client, QByteArrayView payload) {
    try {
      const bool active = client.key.machine.slot == store_.machines().active();
      const HostCommands handler{*this, active};
      const auto notification_revision = client.session.notificationRevision();
      const auto graphics_revision = client.session.graphicsRecoveryRevision();
      const auto change = client.session.consume(byteView({payload.data(), static_cast<std::size_t>(payload.size())}), handler);
      // Terminal frames and documents reach their panes directly, and are the bulk of the
      // traffic; every other change may move what the projections read.
      if (change != Change::none && change != Change::terminal && change != Change::document) {
        store_.touch();
      }
      if (change == Change::stopped || change == Change::closed) {
        client.connection.finishSession();
        if (change == Change::closed) {
          client.session.disconnected();
        }
      }

      static_cast<void>(client.session.settlePresentation());
      summarizeMachine(client.key);
      if (active && client.key.machine.slot != Machines::local_slot && (change == Change::stopped || change == Change::closed)) {
        selectMachine(store_.machines().token(Machines::local_slot));
        return;
      }

      settleActivity();
      if (!active) {
        if (change == Change::model || change == Change::stopped) {
          refresh_timer_.start();
        }

        return;
      }

      if (notification_revision != session().notificationRevision()) {
        refreshNotifications();
      }

      if (graphics_revision != session().graphicsRecoveryRevision()) {
        refreshPanes();
        scheduleGraphicsRecovery();
      }

      presentChange(change);
    } catch (const std::exception& error) {
      if (client.key.machine.slot == store_.machines().active()) {
        fail(error);
        store_.touch();
      } else {
        client.connection.recover(error.what());
      }
    }
  }

  void Application::presentChange(Change change) {
    switch (change) {
    case Change::configuration:
      emit configurationChanged();
      refresh();
      break;
    case Change::terminal:
      reconcileAttachmentFrame(session().changedPane());
      emit terminalChanged(session().changedPane());
      if (session().takeChromeChange() && !refresh_timer_.isActive()) {
        refresh_timer_.start();
      }

      if (store_.dialog().kind == Dialog::paths) {
        emit pathPickerGeometryChanged();
      }

      requestTerminalFrame();
      break;
    case Change::paths:
      refreshPathPicker();
      break;
    case Change::suggestion:
      emit paletteChanged();
      break;
    case Change::peek:
      refreshPeek();
      publishStatus();
      break;
    case Change::document:
      emit documentChanged(session().changedPane());
      // Inline documents take rows of the view, or give them back.
      emit terminalChanged(session().changedPane());
      requestTerminalFrame();
      break;
    case Change::copy_mode:
      emit copySearchChanged();
      publishStatus();
      if (const auto& copy = session().copyMode().state()) {
        emit terminalChanged(copy->pane_id);
      }

      break;
    case Change::clipboard:
      QGuiApplication::clipboard()->setText(toQString(session().clipboard()));
      break;
    case Change::history:
      // The store was touched when the payload arrived; the dialog synchronizes on its flush.
      break;
    case Change::notification:
      break;
    case Change::metrics:
      emit hostMetricsChanged();
      break;
    case Change::model:
      if (!refresh_timer_.isActive()) {
        refresh_timer_.start();
      }

      break;
    case Change::stopped:
    case Change::closed:
      if (window_ != nullptr) {
        window_->close();
      }

      break;
    case Change::none:
      break;
    }
  }

  void Application::HostCommands::operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const {
    if (!active) {
      UnsupportedClientCommand{}(message, reply);
    } else if (!answerConfiguration(application, message, reply)) {
      application.executeHostCommand(message, reply);
    }
  }

  bool Application::answerConfiguration(tbc::view<Application&, tbc::lt::a> application, const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) {
    switch (message.action) {
    case ClientAction::config_show: {
      // The query rewrites the source's buffer, so the state views a copy of the title, not the session.
      const auto title = application.configuration().window_title;
      auto state = application.session().clientViewState();

      state.window_title = title.view();
      reply.text = application.configuration_source_.query(ConfigurationQuery::parse(message.text, message.value), state);

      return true;
    }
    case ClientAction::plugin_list:
    case ClientAction::plugin_get: {
      const auto page = application.configuration_source_.queryPlugins(message);

      reply.text = page.text;
      reply.value = page.next;

      return true;
    }
    default:
      return false;
    }
  }

  void Application::executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    switch (message.action) {
    case ClientAction::plugin_enable:
    case ClientAction::plugin_disable:
      configuration_source_.setPluginEnabled(message, message.action == ClientAction::plugin_enable);
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::plugin_run:
      startPlugin(configuration_source_.pluginInvocation(message, bindingContext()));
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::config_reload:
      configuration_source_.requestReload();
      reply.status = ClientCommandStatus::admitted;
      break;
    // Name prompts: none opens over copy mode or another prompt, and
    // copy mode does not start over a prompt.
    case ClientAction::client_open_goto:
      if (copyModeActive() || store_.dialog().kind != Dialog::none) {
        throw EncodingError{"ClientPromptUnavailable"};
      }

      executeWindowAction(Action::goto_picker);
      break;
    case ClientAction::client_open_history:
      if (copyModeActive() || store_.dialog().kind != Dialog::none) {
        throw EncodingError{"ClientPromptUnavailable"};
      }

      executeWindowAction(Action::history);
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::client_copy_mode:
      if (!copyModeActive()) {
        if (store_.dialog().kind != Dialog::none) {
          throw EncodingError{"CopyModeUnavailable"};
        }

        executeWindowAction(Action::copy_mode);
        if (!copyModeActive()) {
          throw EncodingError{"CopyModeUnavailable"};
        }
      }

      break;
    case ClientAction::client_open_link: {
      const auto target = LinkTarget::fromUri(message.text);
      if (!target) {
        throw EncodingError{"InvalidLink"};
      }

      const auto* focused = session().focusedPane();
      if (!openLink(*target, focused == nullptr ? std::nullopt : std::optional{focused->id})) {
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

  void Application::refresh() {
    synchronize();
    refreshPeek();
    refreshPalette();
    refreshElementBars();
    if (store_.dialog().kind == Dialog::paths) {
      emit pathPickerGeometryChanged();
    }

    scheduleGraphicsRecovery();
    publishStatus();
    publishAttachmentGeometry();
    emit refreshed();
    reconsiderFrame();
  }

  void Application::refreshPanes() {
    synchronizeAttachments();
    panes_.setScale(terminal_grid_.scale);
    panes_.synchronize();
  }

  void Application::resizeDivider(int index, qreal x, qreal y, bool commit) {
    try {
      auto* tab = session().activeTab();
      if (tab == nullptr || tab->fullscreen || !std::isfinite(x) || !std::isfinite(y) || index < 0) {
        return;
      }

      const auto dividers = tab->layout.dividers();
      const auto divider = std::ranges::find_if(dividers, [&](const auto& entry) {
        return entry.node_index == static_cast<std::size_t>(index);
      });
      if (divider == dividers.end()) {
        return;
      }

      const auto& geometry = session().workbenchGeometry();
      const auto parent_bounds = geometry.pixels(divider->parent_bounds);
      const auto divider_bounds = geometry.pixels(divider->bounds);
      const bool horizontal = divider->axis == ClientLayoutAxis::horizontal;
      const auto extent = horizontal ? parent_bounds.width - divider_bounds.width : parent_bounds.height - divider_bounds.height;
      const auto offset = horizontal ? (x * terminal_grid_.scale) - parent_bounds.x - (divider_bounds.width / 2) : (y * terminal_grid_.scale) - parent_bounds.y - (divider_bounds.height / 2);

      if (extent <= 0) {
        return;
      }

      const auto ratio = static_cast<std::uint16_t>(std::clamp(offset / extent, 0.0, 1.0) * PaneLayout::ratio_maximum);
      if (tab->layout.setSplitRatio({.node_index = static_cast<std::size_t>(index), .ratio = ratio})) {
        session().invalidateView();
        refreshPanes();
      }

      if (commit) {
        session().retainLayout();
      }
    } catch (const std::exception& error) {
      fail(error);
    }
  }

  void Application::execute(Action action, const QString& target) {
    key_bindings_.cancelSequence();
    applyInteraction([&] {
      if (action != Action::copy_mode && (action != Action::cancel || store_.dialog().kind == Dialog::none)) {
        leaveKeyboardCopyMode();
      }

      if (!executeNavigation(action, target) && !executePane(action, target.toULongLong())) {
        executeWindowAction(action);
      }
    });
  }

  void Application::submitDialog(const QVariantMap& input) {
    applyInteraction([&] {
      const auto name = input.value(QStringLiteral("text")).toString().toUtf8();
      const auto path = input.value(QStringLiteral("path")).toString().toUtf8();
      const std::string_view text{name.constData(), static_cast<std::size_t>(name.size())};

      if (store_.dialog().kind == Dialog::new_workspace) {
        if (!submitWorkspace(input)) {
          return;
        }
      } else if (store_.dialog().kind == Dialog::rename_tab) {
        session().renameTab(text);
      } else if (store_.dialog().kind == Dialog::rename_workspace) {
        session().renameWorkspace(text);
      } else if (store_.dialog().kind == Dialog::copy_search) {
        session().searchCopy(text);
      }

      showDialog(Dialog::none);
    });
  }

  void Application::interacted() {
    // Exceptions stay on this side of the signal that delivered the interaction.
    try {
      publishPromptWrite();
      refresh();
    } catch (const std::exception& error) {
      interactionFailed(error);
    }
  }

  void Application::synchronize() {
    synchronizeTabStrip();
    workspaces_.synchronize();
    tabs_.synchronize();
    refreshAgents();
    refreshPanes();
    history_.synchronize();
  }

  void Application::interactionFailed(const std::exception& error) {
    if (store_.dialog().kind == Dialog::history) {
      history_.fail(error);
    } else {
      fail(error);
    }
  }

  bool Application::executeNavigation(Action action, const QString& target) {
    const auto identity = target.toULongLong();

    if (action == Action::new_tab) {
      session().createTab();
    } else if (action == Action::select_tab) {
      if (const auto* active = session().activeTab()) {
        session().selectTab({.workspace = active->location.workspace, .tab_id = identity});
      }
    } else if (action == Action::select_tab_index) {
      session().selectTabIndex(static_cast<std::size_t>(identity));
    } else if (action == Action::next_tab || action == Action::previous_tab) {
      session().selectTabOffset(action == Action::next_tab ? 1 : -1);
    } else if (action == Action::move_tab_next || action == Action::move_tab_previous) {
      session().moveTab(action == Action::move_tab_next ? TabMoveDirection::next : TabMoveDirection::previous);
    } else if (action == Action::close_tab) {
      if (const auto* active = session().activeTab()) {
        session().closeTab({.workspace = active->location.workspace, .tab_id = identity == 0 ? active->location.tab_id : identity});
      }
    } else if (action == Action::select_workspace) {
      session().selectWorkspace(parseLocation(target));
    } else if (action == Action::leave_worktree) {
      session().leaveWorktree();
    } else if (action == Action::forget_gone_worktrees) {
      session().forgetGoneWorktrees();
    } else if (action == Action::select_agent) {
      selectActivity(target);
    } else {
      return false;
    }

    return true;
  }

  bool Application::executePane(Action action, std::uint64_t identity) {
    if (action == Action::focus_left || action == Action::focus_right || action == Action::focus_up || action == Action::focus_down) {
      session().focusDirection(paneDirection(action));
    } else if (action == Action::resize_left || action == Action::resize_right || action == Action::resize_up || action == Action::resize_down) {
      session().resizeDirection(paneDirection(action));
    } else if (action == Action::focus_pane) {
      session().focusPane(identity);
    } else if (action == Action::split_horizontal) {
      session().split(ClientLayoutAxis::horizontal);
    } else if (action == Action::split_vertical) {
      session().split(ClientLayoutAxis::vertical);
    } else if (action == Action::close_pane) {
      if (const auto* pane = session().focusedPane()) {
        session().closePane(identity == 0 ? pane->id : identity);
      }
    } else if (action == Action::fullscreen) {
      session().toggleFullscreen();
    } else {
      return false;
    }

    return true;
  }

  void Application::executeWindowAction(Action action) {
    if (executeMachineAction(action)) {
      return;
    }

    if (action == Action::detach) {
      if (window_ != nullptr) {
        window_->close();
      }
    } else if (action == Action::toggle_sidebar) {
      session().setSidebarVisible(!session().configuration().sidebar_visible);
      emit configurationChanged();
    } else if (action == Action::toggle_workspace_list) {
      session().setWorkspaceListCollapsed(!session().workspaceListCollapsed());
      emit configurationChanged();
    } else if (action == Action::history) {
      showDialog(Dialog::history);
      history_.open();
    } else if (action == Action::palette || action == Action::goto_picker) {
      showPalette(action == Action::palette ? PaletteMode::actions : PaletteMode::navigate);
    } else if (action == Action::path_picker) {
      showPathPicker();
    } else if (action == Action::suggest_command) {
      showPalette(PaletteMode::suggest);
    } else if (action == Action::new_workspace || action == Action::rename_tab || action == Action::rename_workspace) {
      showDialog(dialogFor(action));
    } else if (action == Action::copy_mode) {
      if (store_.dialog().kind == Dialog::none && session().enterBlocks()) {
        emit promptChanged(session().changedPane());
        emit terminalChanged(session().changedPane());
      } else if (store_.dialog().kind == Dialog::none) {
        static_cast<void>(session().enterCopyMode());
        publishStatus();
        if (const auto& copy = session().copyMode().state()) {
          emit terminalChanged(copy->pane_id);
        }
      }
    } else if (action == Action::cancel) {
      cancelCurrentInteraction();
    }
  }

  void Application::cancelCurrentInteraction() {
    session().invalidateSuggestion();
    if (restorePaletteParent()) {
      return;
    }

    const auto& copy = session().copyMode().state();
    if (store_.dialog().kind == Dialog::none && copy && !copy->pointer) {
      const auto pane_id = copy->pane_id;

      session().leaveCopyMode();
      emit terminalChanged(pane_id);
      publishStatus();
    }

    showDialog(Dialog::none);
  }

  void Application::setSidebarWidth(qreal width) {
    session().setSidebarWidth(static_cast<float>(std::clamp(width, qreal{Configuration::minimum_sidebar_width}, qreal{Configuration::maximum_sidebar_width})));
    emit configurationChanged();
  }

  void Application::synchronizeFontMetrics() {
    const auto scale = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
    const auto resolved = resolveFont(scale);
    const auto& font = resolved.font;

    cell_metrics_.width = static_cast<float>(font.cell.width());
    cell_metrics_.height = static_cast<float>(font.cell.height());
    cell_metrics_.baseline = static_cast<float>(font.baseline);
    cell_metrics_.pixels = resolved.grid.pixel_height;
    terminal_grid_ = {.cell_width_px = resolved.grid.width, .cell_height_px = resolved.grid.height, .scale = scale};
  }

  bool Application::updateViewport(qreal width, qreal height) {
    constexpr qreal maximum_dimension = std::numeric_limits<std::uint16_t>::max();

    if (!std::isfinite(width) || !std::isfinite(height)) {
      return false;
    }

    const Viewport next{.width = static_cast<std::uint32_t>(std::clamp(width, 0.0, maximum_dimension)), .height = static_cast<std::uint32_t>(std::clamp(height, 0.0, maximum_dimension)), .scale = 1};
    if (viewport_ != next) {
      session().invalidateView();
      viewport_ = next;

      return true;
    }

    return false;
  }

  void Application::synchronizeWindowSize() {
    if (window_ != nullptr && updateViewport(window_->width(), window_->height())) {
      emit windowGeometryChanged();
      refreshPanes();
    }
  }

  bool Application::input(std::uint64_t pane_id, const QByteArray& bytes, PaneInputSource source) {
    const auto* const current = session().findPane(pane_id);
    if (current == nullptr || !current->attached || current->exited || bytes.isEmpty()) {
      return false;
    }

    const auto& copy = session().copyMode().state();
    const auto previous = copy && copy->pointer ? copy->pane_id : 0;
    bool delivered = false;

    try {
      session().input(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())}, source);
      delivered = true;
    } catch (const std::exception& error) {
      fail(error);
    }

    if (previous != 0 && !session().copyMode().state()) {
      publishCopyChange(previous);
    }

    return delivered;
  }

  void Application::paste(std::uint64_t pane_id, const QString& text) {
    try {
      const auto bytes = text.toUtf8();

      session().paste(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    } catch (const std::exception& error) {
      fail(error);
    }

    publishPromptWrite();
  }

  void Application::resize(std::uint64_t pane_id, TerminalSize size) {
    try {
      session().resize(pane_id, size);
    } catch (const std::exception& error) {
      fail(error);
    }
  }

  void Application::scroll(PaneScrollDelta delta) {
    try {
      session().scroll(delta);
    } catch (const std::exception& error) {
      fail(error);
    }
  }

  void Application::showDialog(Dialog kind) {
    if (kind != Dialog::peek) {
      session().closePeek();
      peek_origin_.reset();
      peek_editor_.clear();
    }

    if (kind != Dialog::machine) {
      machine_prompt_.reset();
    }

    if (kind != Dialog::palette) {
      palette_parent_.reset();
      palette_editor_restore_ = {};
    }

    if (store_.dialog().kind == Dialog::paths && kind != Dialog::paths) {
      session().closePathPicker();
    }

    key_bindings_.cancelSequence();
    store_.advanceDialog();
    history_.retire();
    pointer_dispatcher_.presentHistoryActions({});

    if (kind == Dialog::new_workspace || store_.dialog().kind == Dialog::new_workspace) {
      resetWorkspaceForm();
    }

    // The focused pane's prompt line hosts the history and path searches while its shell waits
    // for a command; anywhere else they open as a dialog. The scrollback search lives in the
    // line of the pane copy mode reads, whatever runs there.
    const auto* focused = session().focusedPane();
    const bool searching = kind == Dialog::history || kind == Dialog::paths;
    const auto& copy = session().copyMode().state();
    std::uint64_t line_search_pane = 0;
    if (kind == Dialog::copy_search && copy) {
      line_search_pane = copy->pane_id;
    } else {
      line_search_pane = searching && focused != nullptr && session().promptSurface(focused->id) == prompt::Surface::editor ? focused->id : 0;
    }

    store_.setDialog(kind, line_search_pane);
    emit dialogChanged();
  }

  void Application::fail(const std::exception& error) {
    error_ = QString::fromUtf8(error.what());
    publishStatus();
  }

  void Application::publishConfiguration() {
    // Qt notifies QML bindings before any connected slot, so the cache is dropped before the
    // signal rather than in a slot of it.
    colors_.reset();
    font_.reset();
    emit configurationChanged();
  }

  // Each pane delegate reads the theme a score of times; it is built once per configuration.
  QVariantMap Application::colors() const {
    if (!colors_) {
      colors_ = themeColors(session().configuration());
    }

    return *colors_;
  }

  QVariantMap Application::font() const {
    if (!font_) {
      font_ = fontSettings(session().configuration().font);
    }

    return *font_;
  }

  ResolvedFont Application::resolveFont(qreal scale) {
    return configuration_source_.resolveFont(session().configuration().font, scale);
  }

  bool Application::sidebarVisible() const {
    return session().configuration().sidebar_visible;
  }

  qreal Application::sidebarWidth() const {
    return session().configuration().sidebar_width;
  }

  bool Application::workspaceListCollapsed() const {
    return session().workspaceListCollapsed();
  }

  qreal Application::windowControls() const {
    return window_ == nullptr ? 0 : platform::windowControls(*window_);
  }

  Application::Dialog Application::dialog() const noexcept {
    return store_.dialog().kind;
  }

  Application::Dialog Application::lineSearch() const noexcept {
    return store_.dialog().line_search_pane == 0 ? Dialog::none : store_.dialog().kind;
  }

  QString Application::lineSearchPane() const {
    return store_.dialog().line_search_pane == 0 ? QString{} : QString::number(store_.dialog().line_search_pane);
  }

  bool Application::connected() const {
    return connection().ready();
  }

  QString Application::title() const {
    const auto title = session().windowTitle({hostname_.constData(), static_cast<std::size_t>(hostname_.size())});

    return toQString(title.view());
  }

  bool Application::prefixPending() const noexcept {
    return key_bindings_.prefixPending();
  }

  QVariantMap Application::statusMode() const {
    if (prefixPending()) {
      return statusModeRecord(StatusMode::prefix, key_bindings_.modeHints());
    }

    return statusModeRecord(copyModeActive() ? StatusMode::copy : StatusMode::normal);
  }

  QVariantMap Application::hostMetrics() const {
    return metricsRecord(session().hostMetrics());
  }

  QString Application::tlsBadgeColor() const {
    const auto& proxy = session().proxyStatus();
    if (!proxy.active && !proxy.system_trusted) {
      return {};
    }

    if (!proxy.active) {
      return QStringLiteral("yellow");
    }

    return proxy.scope == ProxyScope::wildcard ? QStringLiteral("red") : QStringLiteral("peach");
  }

  void Application::dismissDiagnostic() {
    error_.clear();
    session().dismissDiagnostic();
    connection().dismissError();
    publishStatus();
  }

  void Application::publishStatus() {
    auto& published = published_status_;
    auto title = this->title();
    if (title != published.title) {
      published.title = std::move(title);
      emit titleChanged();
    }

    auto error = this->error();
    auto tls_badge_color = tlsBadgeColor();
    const auto connected = this->connected();
    if (error != published.error || tls_badge_color != published.tls_badge_color || connected != published.connected) {
      published.error = std::move(error);
      published.tls_badge_color = std::move(tls_badge_color);
      published.connected = connected;
      emit diagnosticChanged();
    }

    if (const auto copy_mode = copyModeActive(); copy_mode != published.copy_mode) {
      published.copy_mode = copy_mode;
      emit copyModeChanged();
    }
  }

  QString Application::error() const {
    if (!error_.isEmpty()) {
      return error_;
    }

    return toQString(session().error());
  }

}
