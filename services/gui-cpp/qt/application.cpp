#include "application.hpp"
#include "activity_projection.hpp"
#include "agent_projection.hpp"
#include "application/dependencies.hpp"
#include "application/pane_layout.hpp"
#include "application/records.hpp"
#include "application/session.hpp"
#include "application/workbench_geometry.hpp"
#include "application_effects.hpp"
#include "config/query.hpp"
#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "core/terminal_size.hpp"
#include "history/search.hpp"
#include "links/link_target.hpp"
#include "login_shell.hpp"
#include "metrics_projection.hpp"
#include "mode_projection.hpp"
#include "palette/query.hpp"
#include "pane_projection.hpp"
#include "platform/awake_clock.hpp"
#include "platform/host_name.hpp"
#include "platform/window.hpp"
#include "presentation/activity_card.hpp"
#include "presentation/activity_order.hpp"
#include "presentation/frame_pacer.hpp"
#include "presentation/mode_hints.hpp"
#include "project_projection.hpp"
#include "projection.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal_item.hpp"
#include "text/utf16_prefix.hpp"
#include "ui/workbench/terminal_font.hpp"
#include "window_animation_clock.hpp"
#include "window_font_catalog.hpp"
#include "window_images.hpp"
#include <QAbstractItemModel>
#include <QClipboard>
#include <QCryptographicHash>
#include <QDir>
#include <QEvent>
#include <QGuiApplication>
#include <QPointer>
#include <QQuickItem>
#include <QRandomGenerator>
#include <QScreen>
#include <QStringView>
#include <QVariant>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlist.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qstring.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <variant>

namespace telar::gui::qt {

namespace {

auto parseLocation(const QString &key) -> WorkspaceLocation {
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

auto dialogName(Application::Action action) -> QString {
  using Action = Application::Action;
  switch (action) {
  case Action::palette:
    return QStringLiteral("palette");
  case Action::new_workspace:
    return QStringLiteral("new-workspace");
  case Action::rename_tab:
    return QStringLiteral("rename-tab");
  case Action::rename_workspace:
    return QStringLiteral("rename-workspace");
  default:
    return {};
  }
}

}

Application::Application(ApplicationAllocator &memory, QObject *parent)
    : QObject(parent),
      memory_(memory),
      connection_(memory),
      configuration_source_(memory),
      session_(memory, connection_, ApplicationEffects{*this}),
      key_bindings_(*this),
      pointer_dispatcher_(*this),
      link_opener_(*this),
      sound_player_(*this),
      system_notifier_(memory),
      hostname_(platform::hostName()),
      identity_(QRandomGenerator::system()->generate64() | std::uint64_t{1}) {
  key_bindings_.configure(configuration_source_.input(), configuration_source_.keymap());

  connect(this, &Application::configurationChanged, this, &Application::windowGeometryChanged);
  connect(this, &Application::stateChanged, this, &Application::statusModeChanged);
  connect(this, &Application::configurationChanged, this, &Application::paletteChanged);
  connect(this, &Application::windowGeometryChanged, this, &Application::paletteChanged);
  connect(this, &Application::windowGeometryChanged, this, &Application::pathPickerGeometryChanged);
  connect(this, &Application::pathPickerChanged, this, &Application::pathPickerGeometryChanged);
  connect(this, &Application::prefixChanged, this, &Application::statusModeChanged);
  connect(this, &Application::windowGeometryChanged, this, &Application::synchronizeWorkbenchGeometry);
  connect(this, &Application::windowGeometryChanged, this, &Application::sidebarGeometryChanged);
  connect(this, &Application::windowGeometryChanged, this, &Application::historyChanged);
  connect(&workspaces_, &QAbstractItemModel::rowsInserted, this, &Application::sidebarGeometryChanged);
  connect(&workspaces_, &QAbstractItemModel::rowsRemoved, this, &Application::sidebarGeometryChanged);
  connect(&workspaces_, &QAbstractItemModel::rowsMoved, this, &Application::sidebarGeometryChanged);
  connect(&workspaces_, &QAbstractItemModel::dataChanged, this, &Application::sidebarGeometryChanged);

  const login_shell::Command shell;
  const auto directory = QDir::currentPath().toUtf8();

  session_.setLaunch(Launch{
      .cwd = {
          directory.constData(),
          static_cast<std::size_t>(directory.size()),
      },
      .arguments = shell.arguments(),
  });

  refresh_timer_.setSingleShot(true);
  history_timer_.setSingleShot(true);
  initializeNotifications();
  initializeGraphicsRecovery();

  constexpr int history_debounce_ms = 60;
  history_timer_.setInterval(history_debounce_ms);

  connect(&connection_, &RuntimeConnection::connected, this, [this] {
    session_.connected(identity_);
    emit stateChanged();
  });

  connect(&connection_, &RuntimeConnection::payloadReceived, this, &Application::consume, Qt::DirectConnection);
  connect(&connection_, &RuntimeConnection::paneWillDetach, this, &Application::inputReleasing, Qt::DirectConnection);

  connect(&connection_, &RuntimeConnection::disconnected, this, &Application::runtimeDisconnected);

  connect(&connection_, &RuntimeConnection::errorChanged, this, &Application::stateChanged);

  connect(&configuration_source_, &ConfigurationSource::changed, this, [this] {
    error_.clear();
    key_bindings_.configure(configuration_source_.input(), configuration_source_.keymap());
    session_.configure(configuration_source_.configuration());
    synchronizeFontMetrics();
    if (session_.ready()) {
      session_.configureCadence();
    }

    emit configurationChanged();
    emit historyChanged();
    configureWindow();
    refresh();
  });

  connect(&configuration_source_, &ConfigurationSource::failed, this, [this] {
    error_ = configuration_source_.error();
    emit stateChanged();
  });

  connect(&configuration_source_, &ConfigurationSource::themeChanged, this, [this] {
    session_.setTheme(configuration_source_.configuration().theme);
    emit configurationChanged();
    refresh();
  });

  connect(&refresh_timer_, &QTimer::timeout, this, &Application::refresh);

  connect(&history_timer_, &QTimer::timeout, this, [this] {
    try {
      const auto query = history_query_.toUtf8();
      session_.queryHistory(std::string_view{query.constData(), static_cast<std::size_t>(query.size())}, history_filters_);
    } catch (const std::exception &error) {
      fail(error);
    }
    refreshHistory();
  });

  synchronizeWorkbenchGeometry();
}

void Application::runtimeDisconnected() {
  session_.disconnected();
  if (dialog_ == QLatin1StringView("palette")) {
    emit paletteChanged();
  }

  if (dialog_ == QLatin1StringView("paths")) {
    showDialog({});
  }

  scheduleGraphicsRecovery();
  emit hostMetricsChanged();
  refresh_timer_.start();
}

void Application::loadConfiguration(const QString &path, const QString &profile, const QString &theme) {
  configuration_source_.open({.path = path, .profile = profile, .theme = theme});
}

void Application::configureLaunch(const QString &directory, const QStringList &arguments, bool restore) {
  const auto cwd = QDir{directory.isEmpty() ? QDir::currentPath() : directory}.absolutePath().toUtf8();
  const login_shell::Command shell;
  constexpr std::size_t maximum_arguments = 32;

  if (arguments.size() > static_cast<qsizetype>(maximum_arguments)) {
    throw std::length_error{"Launch command exceeds its argument capacity"};
  }

  QList<QByteArray> storage;
  storage.reserve(arguments.size());

  for (const auto &argument : arguments) {
    storage.append(argument.toUtf8());
  }

  std::array<std::string_view, maximum_arguments> views{};
  for (qsizetype index = 0; index < storage.size(); ++index) {
    views[static_cast<std::size_t>(index)] = {storage[index].constData(), static_cast<std::size_t>(storage[index].size())};
  }

  const auto command = arguments.isEmpty() ? shell.arguments() : std::span<const std::string_view>{views}.first(static_cast<std::size_t>(storage.size()));
  session_.setLaunch(Launch{.cwd = {cwd.constData(), static_cast<std::size_t>(cwd.size())}, .arguments = command});
  session_.setRestoreLayout(restore);
}

Application::~Application() {
  if (window_ != nullptr) {
    window_->removeEventFilter(this);
    window_->disconnect(this);
  }

  frame_pacer_.reset();
  QObject::disconnect(screen_refresh_connection_);
  connection_.disconnect(this);
  connection_.close();
}

void Application::open(const QString &endpoint) {
  const auto path = endpoint.toUtf8();
  identity_lease_.emplace(std::string_view{path.constData(), static_cast<std::size_t>(path.size())});
  QCryptographicHash hash{QCryptographicHash::Sha256};
  constexpr auto identity_namespace = std::to_array("telar-gui-window-v1");
  const auto canonical_endpoint = identity_lease_->endpoint();
  hash.addData(QByteArrayView{identity_namespace.data(), static_cast<qsizetype>(identity_namespace.size())});
  hash.addData(QByteArrayView{canonical_endpoint.data(), static_cast<qsizetype>(canonical_endpoint.size())});
  constexpr char separator = '\0';
  hash.addData(QByteArrayView{&separator, 1});
  const auto slot = static_cast<char>(identity_lease_->slot());
  hash.addData(QByteArrayView{&slot, 1});
  const auto digest = hash.result();
  auto identity_bytes = byteView({digest.constData(), static_cast<std::size_t>(digest.size())}).first(sizeof(std::uint64_t));
  identity_ = u64::decode(identity_bytes) | std::uint64_t{1};
  connection_.open(endpoint);
}

void Application::setWindow(QQuickWindow &window) {
  if (window_ == &window) {
    return;
  }

  if (window_ != nullptr) {
    window_->removeEventFilter(this);
    window_->disconnect(this);
  }

  window_ = &window;
  ++window_generation_;
  frame_pacer_.reset();
  frame_pacer_.emplace(window);
  presented_history_.reset();
  presented_history_surface_ = {};
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
  } catch (const std::exception &error) {
    fail(error);
  }
}

bool Application::eventFilter(QObject *watched, QEvent *event) {
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

void Application::observeFrames(QQuickWindow &window) {
  WindowImages::forWindow(window);
  connect(&window, &QQuickWindow::afterAnimating, this, &Application::prepareImagePlacements);
  const auto generation = window_generation_;
  const auto preparation = std::allocate_shared<PresentedFrame>(AllocatorRef<PresentedFrame, ApplicationAllocator>{memory_});
  connect(&window, &QQuickWindow::beforeSynchronizing, this, [this, preparation, generation] {
    if (generation == window_generation_) {
      prepareFrame(*preparation);
    }
  },
          Qt::DirectConnection);
  connect(&window, &QQuickWindow::afterSynchronizing, this, [this, preparation, generation] {
    if (generation == window_generation_) {
      prepareTerminalFrames(*preparation);
      recordPreparedFrame(*preparation);
    }
  },
          Qt::DirectConnection);

  connect(
      &window,
      &QQuickWindow::frameSwapped,
      this,
      [this, preparation, generation] {
        QMetaObject::invokeMethod(
            this,
            [this, frame = *preparation, generation] {
              if (window_ != nullptr && generation == window_generation_) {
                present(frame);
              }
            },
            Qt::QueuedConnection);
      },
      Qt::DirectConnection);
}

PointerDispatcher &Application::pointerDispatcher() noexcept {
  return pointer_dispatcher_;
}

void Application::prepareImagePlacements() {
  if (window_ == nullptr) {
    return;
  }

  std::array<ImagePlacementSource, PaneLayout::maximum_panes> sources;
  std::size_t count = 0;
  const auto *tab = session_.activeTab();
  if (tab != nullptr) {
    for (const auto &node : tab->layout.nodes()) {
      const auto *leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf == nullptr || (tab->fullscreen && leaf->pane_id != tab->focused_pane)) {
        continue;
      }

      const auto *pane = session_.findPane(leaf->pane_id);
      const auto terminal = terminals_.constFind(leaf->pane_id);
      if (pane != nullptr && pane->attached && terminal != terminals_.cend() && *terminal != nullptr && (*terminal)->window() == window_ && (*terminal)->isVisible()) {
        sources[count++] = {.owner = *terminal, .store = &pane->graphics, .cell = (*terminal)->cellSize()};
      }
    }
  }

  if (const auto reach = WindowImages::forWindow(*window_).preparePlacements(std::span{sources}.first(count))) {
    session_.reportLimit(*reach);
    refreshNotifications();
  }
}

void Application::prepareFrame(PresentedFrame &frame) {
  frame = {};
  frame.preparation_ns = platform::AwakeClock::nowNanoseconds();
  if (window_ != nullptr) {
    auto *images = WindowImages::findWindow(*window_);
    if (images != nullptr && !images->empty()) {
      images->beginCatalogSnapshot();
      for (const auto &pane : session_.panes()) {
        images->observeCatalog(pane->graphics);
      }
    }
  }

  if (window_ == nullptr) {
    return;
  }

  const auto &history = session_.historyBrowser();
  if (dialog_ == QLatin1StringView("history") && !historyLoading() && history_view_version_ == history.viewVersion()) {
    frame.history_surface = historyScrollSurface(historyMetrics());

    if (const auto choice = history.choice()) {
      frame.history = {.choice = *choice, .dialog_generation = dialog_generation_, .enter_runs = session_.configuration().history.enter_runs};
    }
  }
}

void Application::prepareTerminalFrames(PresentedFrame &frame) {
  if (window_ == nullptr) {
    return;
  }

  const auto *tab = session_.activeTab();
  if (tab == nullptr) {
    return;
  }

  for (const auto &node : tab->layout.nodes()) {
    const auto *leaf = std::get_if<ClientLayoutPane>(&node);
    if (leaf == nullptr || (tab->fullscreen && leaf->pane_id != tab->focused_pane)) {
      continue;
    }

    if (const auto *pane = session_.findPane(leaf->pane_id); pane != nullptr && pane->attached) {
      auto *terminal = visibleTerminal(pane->id);
      if (terminal == nullptr) {
        continue;
      }

      const auto &prepared = terminal->prepared_frame_;
      if (!prepared.pane.attached || prepared.pane.pane_id != pane->id || prepared.pane.attachment_generation != pane->attachment_generation) {
        continue;
      }

      frame.panes[frame.pane_count++] = {.frame = prepared, .terminal = terminal};
    }
  }
}

TerminalItem *Application::visibleTerminal(std::uint64_t pane_id) const {
  const auto terminal = terminals_.constFind(pane_id);
  if (terminal == terminals_.cend() || *terminal == nullptr || (*terminal)->window() != window_ || !(*terminal)->isVisible() || !(*terminal)->flags().testFlag(QQuickItem::ItemHasContents) || (*terminal)->width() <= 0 || (*terminal)->height() <= 0) {
    return nullptr;
  }

  return *terminal;
}

std::size_t Application::collectPacingPanes(std::span<FramePacer::Pane, PaneLayout::maximum_panes> panes) const {
  const auto *tab = session_.activeTab();
  if (window_ == nullptr || tab == nullptr) {
    return 0;
  }

  std::size_t count = 0;
  for (const auto &node : tab->layout.nodes()) {
    const auto *leaf = std::get_if<ClientLayoutPane>(&node);
    if (leaf == nullptr || (tab->fullscreen && leaf->pane_id != tab->focused_pane) || visibleTerminal(leaf->pane_id) == nullptr) {
      continue;
    }

    if (const auto *pane = session_.findPane(leaf->pane_id); pane != nullptr && pane->attached) {
      panes[count++] = {.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = true, .attachment_generation = pane->attachment_generation};
    }
  }

  return count;
}

void Application::recordPreparedFrame(const PresentedFrame &frame) {
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
    session_.setDisplayRefreshRate(static_cast<std::uint16_t>(std::clamp(std::round(rate), qreal{Configuration::minimum_fps}, qreal{Configuration::maximum_fps})));
    if (session_.ready()) {
      session_.configureCadence();
    }
  }

  configureFramePacer();
}

void Application::configureWindow() {
  if (window_ == nullptr) {
    return;
  }

  const auto &configuration = session_.configuration();
  WindowAnimationClock::forWindow(*window_).setMaximumFrameRate(configuration.max_fps == 0 ? std::nullopt : std::optional{configuration.max_fps});
  configureFramePacer();
  const QPointer<Application> lifetime{this};
  const auto owner = window_;
  WindowFontCatalog::forWindow(*owner).configure(configuration.font);
  if (!lifetime || !owner || window_ != owner) {
    return;
  }

  platform::configureWindow(*window_, {.titlebar = configuration.titlebar.value_or(platform::defaultTitlebar()), .navigation_height = static_cast<float>(ChromeMetrics::logical_top_bar * chromeRatio()), .background_opacity = configuration.background_opacity, .background_blur = configuration.background_blur});
  emit windowGeometryChanged();
}

void Application::present(const PresentedFrame &frame) {
  presented_history_ = frame.history;
  presented_history_surface_ = frame.history_surface;

  try {
    for (const auto &pane : std::span{frame.panes}.first(frame.pane_count)) {
      const auto &identity = pane.frame.pane;
      const auto *current = session_.findPane(identity.pane_id);
      if (current == nullptr || !current->attached || current->attachment_generation != identity.attachment_generation) {
        continue;
      }

      if (pane.terminal != nullptr && pane.terminal->application() == this && pane.terminal->paneIdentity() == identity.pane_id) {
        pane.terminal->presentFrame(pane.frame);
      }

      session_.presented(identity.pane_id, identity.frame_id);
    }
  } catch (const std::exception &error) {
    fail(error);
  }
}

Pane<ApplicationAllocator> *Application::pane(std::uint64_t identity) const noexcept {
  return session_.findPane(identity);
}

const Configuration &Application::configuration() const noexcept {
  return session_.configuration();
}

void Application::consume(QByteArrayView payload) {
  try {
    const auto handler = [this](const ClientCommand &message, CompleteClientCommand &reply) {
      executeHostCommand(message, reply);
    };
    const auto notification_revision = session_.notificationRevision();
    const auto graphics_revision = session_.graphicsRecoveryRevision();
    const auto change = session_.consume(byteView({payload.data(), static_cast<std::size_t>(payload.size())}), handler);
    if (notification_revision != session_.notificationRevision()) {
      refreshNotifications();
    }
    if (graphics_revision != session_.graphicsRecoveryRevision()) {
      refreshPanes();
      scheduleGraphicsRecovery();
    }

    switch (change) {
    case Change::configuration:
      emit configurationChanged();
      refresh();
      break;
    case Change::terminal:
      emit terminalChanged(session_.changedPane());
      if (dialog_ == QLatin1StringView("paths")) {
        emit pathPickerGeometryChanged();
      }

      reconsiderFrame();
      break;
    case Change::paths:
      refreshPathPicker();
      break;
    case Change::suggestion:
      emit paletteChanged();
      break;
    case Change::copy_mode:
      emit stateChanged();
      if (session_.copyMode().state()) {
        emit terminalChanged(session_.copyMode().state().value().pane_id);
      }

      break;
    case Change::clipboard:
      QGuiApplication::clipboard()->setText(toQString(session_.clipboard()));
      break;
    case Change::history:
      refreshHistory();
      break;
    case Change::notification:
      break;
    case Change::metrics:
      emit hostMetricsChanged();
      break;
    case Change::model:
    case Change::stopped:
      if (change == Change::stopped) {
        emit hostMetricsChanged();
      }

      if (!refresh_timer_.isActive()) {
        refresh_timer_.start();
      }
      break;
    case Change::closed:
      if (window_ != nullptr) {
        window_->close();
      }
      break;
    case Change::none:
      break;
    }
  } catch (const std::exception &error) {
    fail(error);
    refreshHistory();
  }
}

void Application::executeHostCommand(const ClientCommand &message, CompleteClientCommand &reply) {
  switch (message.action) {
  case ClientAction::config_show:
    reply.text = configuration_source_.query(ConfigurationQuery::parse(message.text, message.value), session_.clientViewState());
    break;
  case ClientAction::config_reload:
    configuration_source_.requestReload();
    reply.status = ClientCommandStatus::admitted;
    break;
  case ClientAction::client_open_history:
    executeWindowAction(Action::history);
    reply.status = ClientCommandStatus::admitted;
    break;
  case ClientAction::client_open_link: {
    const auto target = LinkTarget::fromUri(message.text);
    if (!target) {
      throw EncodingError{"InvalidLink"};
    }

    const auto *focused = session_.focusedPane();
    if (!openLink(*target, focused == nullptr ? std::nullopt : std::optional{focused->id})) {
      throw EncodingError{"LinkOpeningUnavailable"};
    }

    reply.status = ClientCommandStatus::admitted;
    break;
  }
  default:
    UnsupportedClientCommand{}(message, reply);
    break;
  }
}

void Application::refresh() {
  QList<QVariantMap> workspaces;
  const auto *active = session_.activeTab();
  QVariantMap workspace_context;
  std::optional<std::uint64_t> selected_project;
  if (active != nullptr && active->location.workspace.kind == WorkspaceLocation::Kind::workspace) {
    selected_project = session_.workspaceList().projectOf(active->location.workspace.id);
    const auto current = std::ranges::find_if(session_.workspaces(), [&](const auto &workspace) {
      return sameWorkspace(workspace.location, active->location.workspace);
    });
    if (current != session_.workspaces().end()) {
      workspace_context = workspaceRecord(*current, true);
    }
  }

  for (const auto &workspace : session_.workspaceList().projects()) {
    const bool selected = selected_project == workspace.location.id;
    auto record = projectRecord(workspace, session_.workspaceList(), std::span<const Agent<ApplicationAllocator>>{session_.agents()}, selected);
    record.insert(QStringLiteral("index"), workspaces.size());
    if (selected) {
      workspace_context.insert(QStringLiteral("index"), workspaces.size());
    }

    workspaces.append(std::move(record));
  }

  workspace_context_ = std::move(workspace_context);
  workspaces_.reconcile(std::move(workspaces));

  QList<const Tab<ApplicationAllocator> *> ordered_tabs;
  for (const auto &tab : session_.tabs()) {
    if (active != nullptr && sameWorkspace(tab->location.workspace, active->location.workspace)) {
      ordered_tabs.append(tab.get());
    }
  }

  std::ranges::stable_sort(ordered_tabs, [](const auto *left, const auto *right) {
    return left->position < right->position;
  });
  QList<QVariantMap> tabs;
  for (const auto *tab : ordered_tabs) {
    const auto *pane = session_.findPane(tab->focused_pane);
    tabs.append(tabRecord(*tab, pane, std::span<const Agent<ApplicationAllocator>>{session_.agents()}, tab == active));
  }

  tabs_.reconcile(std::move(tabs));
  refreshAgents();
  refreshHistory();
  refreshPanes();
  refreshPalette();
  if (dialog_ == QLatin1StringView("paths")) {
    emit pathPickerGeometryChanged();
  }

  scheduleGraphicsRecovery();
  emit stateChanged();
  reconsiderFrame();
}

void Application::refreshAgents() {
  QList<QVariantMap> agents;
  const auto *active = session_.activeTab();
  const auto agent_entries = std::span<const Agent<ApplicationAllocator>>{session_.agents()};
  const auto workspace_entries = std::span<const Workspace<ApplicationAllocator>>{session_.workspaces()};
  using Order = ActivityOrder<ApplicationAllocator>;
  const std::array sources{Order::Source{.agents = agent_entries, .workspaces = session_.workspaceList(), .focused = active == nullptr ? std::nullopt : std::optional{active->focused_pane}}};
  Order::Plan order;
  Order::write(sources, sources.front().slot, order);
  for (const auto &entry : order.view()) {
    AgentRecordContext context{.machine = {hostname_.constData(), static_cast<std::size_t>(hostname_.size())}, .branch = {}, .connected = session_.ready(), .coordinator = entry.coordinator, .starts_project = entry.first_in_project, .depth = entry.depth};
    if (!entry.agent) {
      if (!entry.worktree) {
        throw std::logic_error{"ActivityEntryWithoutOwner"};
      }

      agents.append(commandRecord(session_.workspaceList().worktrees()[*entry.worktree], context));
      continue;
    }

    const auto &agent = agent_entries[*entry.agent];
    const auto workspace = std::ranges::find_if(workspace_entries, [&](const auto &candidate) {
      return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(agent.location.workspace, candidate.location);
    });
    context.branch = workspace == workspace_entries.end() ? std::string_view{} : std::string_view{workspace->branch};
    context.selected = active != nullptr && agent.pane_id == active->focused_pane && sameTab(agent.location, active->location);
    if (entry.worktree) {
      agents.append(taskRecord(agent, session_.workspaceList().worktrees()[*entry.worktree], context, entry.card == ActivityCard::task_compact));
    } else {
      agents.append(agentRecord(agent, context));
    }
  }

  agents_.reconcile(std::move(agents));
}

QVariantList Application::fullscreenEntries(const Tab<ApplicationAllocator> &tab) {
  QVariantList entries;
  if (!tab.fullscreen) {
    return entries;
  }

  std::uint16_t index = 0;
  const auto agents = std::span<const Agent<ApplicationAllocator>>{session_.agents()};
  for (const auto &node : tab.layout.nodes()) {
    if (const auto *leaf = std::get_if<ClientLayoutPane>(&node)) {
      ++index;
      entries.append(fullscreenPaneRecord(session_.findPane(leaf->pane_id), agents, {.pane_id = leaf->pane_id, .index = index, .focused = tab.focused_pane == leaf->pane_id}));
    }
  }

  return entries;
}

void Application::refreshPanes() {
  auto *tab = session_.activeTab();
  QList<QVariantMap> panes;
  QList<QVariantMap> dividers;
  if (tab != nullptr) {
    const auto &geometry = session_.workbenchGeometry();
    const auto fullscreen = tab->fullscreen ? std::optional{tab->focused_pane} : std::nullopt;
    const auto fullscreen_entries = fullscreenEntries(*tab);

    for (const auto &placement : tab->layout.arrange(geometry.cellArea(), geometry.layout_metrics, fullscreen)) {
      const auto *pane = session_.findPane(placement.pane_id);
      if (pane == nullptr) {
        continue;
      }

      auto record = paneRecord(*pane, placement, geometry, tab->focused_pane == pane->id, terminal_grid_.scale);
      record.insert(QStringLiteral("fullscreen"), tab->fullscreen);
      if (tab->fullscreen) {
        record.insert(QStringLiteral("fullscreenEntries"), fullscreen_entries);
      }
      record.insert(QStringLiteral("chrome"), paneChromeRecord(*pane, std::span<const Agent<ApplicationAllocator>>{session_.agents()}, placement.display_index, session_.graphicsPaused(pane->id)));
      panes.append(std::move(record));
    }

    for (const auto &divider : tab->layout.dividers()) {
      const auto bounds = geometry.pixels(divider.bounds);
      QVariantMap record;
      record.insert(QStringLiteral("key"), QString::number(divider.node_index));
      record.insert(QStringLiteral("x"), bounds.x / terminal_grid_.scale);
      record.insert(QStringLiteral("y"), bounds.y / terminal_grid_.scale);
      record.insert(QStringLiteral("width"), bounds.width / terminal_grid_.scale);
      record.insert(QStringLiteral("height"), bounds.height / terminal_grid_.scale);
      record.insert(QStringLiteral("horizontal"), divider.axis == ClientLayoutAxis::horizontal);
      dividers.append(record);
    }
  }

  panes_.reconcile(std::move(panes));
  dividers_.reconcile(std::move(dividers));
}

void Application::resizeDivider(int index, qreal x, qreal y, bool commit) {
  try {
    auto *tab = session_.activeTab();
    if (tab == nullptr || tab->fullscreen || !std::isfinite(x) || !std::isfinite(y) || index < 0) {
      return;
    }

    const auto dividers = tab->layout.dividers();
    const auto divider = std::ranges::find_if(dividers, [&](const auto &entry) {
      return entry.node_index == static_cast<std::size_t>(index);
    });
    if (divider == dividers.end()) {
      return;
    }

    const auto &geometry = session_.workbenchGeometry();
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
      session_.invalidateView();
      refreshPanes();
    }

    if (commit) {
      session_.retainLayout();
    }
  } catch (const std::exception &error) {
    fail(error);
  }
}

void Application::execute(Action action, const QString &target) {
  key_bindings_.cancelSequence();
  applyInteraction([&] {
    if (action != Action::copy_mode && (action != Action::cancel || dialog_.isEmpty())) {
      leaveKeyboardCopyMode();
    }

    if (!executeNavigation(action, target) && !executePane(action, target.toULongLong())) {
      executeWindowAction(action);
    }
  });
}

void Application::submitDialog(const QVariantMap &input) {
  applyInteraction([&] {
    const auto name = input.value(QStringLiteral("text")).toString().toUtf8();
    const auto path = input.value(QStringLiteral("path")).toString().toUtf8();
    const std::string_view text{name.constData(), static_cast<std::size_t>(name.size())};
    if (dialog_ == QLatin1StringView("new-workspace")) {
      session_.createWorkspace({.name = text, .path = {path.constData(), static_cast<std::size_t>(path.size())}});
    } else if (dialog_ == QLatin1StringView("rename-tab")) {
      session_.renameTab(text);
    } else if (dialog_ == QLatin1StringView("rename-workspace")) {
      session_.renameWorkspace(text);
    } else if (dialog_ == QLatin1StringView("copy-search")) {
      session_.searchCopy(text);
    }

    showDialog({});
  });
}

void Application::useHistory(const QString &entry_id, bool alternate) {
  submitHistory(entry_id.toULongLong(), alternate);
}

void Application::submitHistory(std::uint64_t entry_id, bool alternate) {
  if (dialog_ != QLatin1StringView("history")) {
    return;
  }

  applyInteraction([&] {
    if (historyLoading()) {
      throw EncodingError{"History search is still loading"};
    }

    session_.pasteHistory(entry_id, alternate);
    error_.clear();
    showDialog({});
  });
}

void Application::useHistoryRow(int row, bool alternate) {
  const auto &entries = session_.history();
  if (row < 0 || static_cast<std::size_t>(row) >= entries.size()) {
    return;
  }

  submitHistory(entries[static_cast<std::size_t>(row)].id, alternate);
}

void Application::usePresentedHistory(const QString &revision, bool alternate) {
  const auto *presented = presentedHistory(revision);
  if (presented == nullptr || presented->enter_runs != session_.configuration().history.enter_runs) {
    return;
  }

  const auto &browser = session_.historyBrowser();
  if (!browser.accepts(presented->choice)) {
    return;
  }

  submitHistory(browser.rows()[presented->choice.index].id, alternate);
}

const Application::PresentedHistory *Application::presentedHistory(const QString &revision) const {
  if (dialog_ != QLatin1StringView("history") || historyLoading() || !presented_history_) {
    return nullptr;
  }

  const auto &presented = *presented_history_;
  if (presented.dialog_generation != dialog_generation_) {
    return nullptr;
  }

  bool valid_revision = false;
  const auto requested_revision = revision.toULongLong(&valid_revision);
  return valid_revision && presented.choice.revision == requested_revision ? &presented : nullptr;
}

bool Application::historyLoading() const {
  return history_timer_.isActive() || session_.historyLoading();
}

bool Application::executeNavigation(Action action, const QString &target) {
  const auto identity = target.toULongLong();
  if (action == Action::new_tab) {
    session_.createTab();
  } else if (action == Action::select_tab) {
    if (const auto *active = session_.activeTab()) {
      session_.selectTab({.workspace = active->location.workspace, .tab_id = identity});
    }
  } else if (action == Action::select_tab_index) {
    session_.selectTabIndex(static_cast<std::size_t>(identity));
  } else if (action == Action::next_tab || action == Action::previous_tab) {
    session_.selectTabOffset(action == Action::next_tab ? 1 : -1);
  } else if (action == Action::move_tab_next || action == Action::move_tab_previous) {
    session_.moveTab(action == Action::move_tab_next ? TabMoveDirection::next : TabMoveDirection::previous);
  } else if (action == Action::close_tab) {
    if (const auto *active = session_.activeTab()) {
      session_.closeTab({.workspace = active->location.workspace, .tab_id = identity == 0 ? active->location.tab_id : identity});
    }
  } else if (action == Action::select_workspace) {
    session_.selectWorkspace(parseLocation(target));
  } else if (action == Action::leave_worktree) {
    session_.leaveWorktree();
  } else if (action == Action::forget_gone_worktrees) {
    session_.forgetGoneWorktrees();
  } else if (action == Action::select_agent && target.startsWith(QLatin1StringView("command:"))) {
    session_.openWorktree(target.section(QLatin1Char(':'), 1).toULongLong());
  } else {
    return false;
  }

  return true;
}

bool Application::executePane(Action action, std::uint64_t identity) {
  if (action == Action::focus_left || action == Action::focus_right || action == Action::focus_up || action == Action::focus_down) {
    session_.focusDirection(paneDirection(action));
  } else if (action == Action::resize_left || action == Action::resize_right || action == Action::resize_up || action == Action::resize_down) {
    session_.resizeDirection(paneDirection(action));
  } else if (action == Action::focus_pane || action == Action::select_agent) {
    session_.focusPane(identity);
  } else if (action == Action::split_horizontal) {
    session_.split(ClientLayoutAxis::horizontal);
  } else if (action == Action::split_vertical) {
    session_.split(ClientLayoutAxis::vertical);
  } else if (action == Action::close_pane) {
    if (const auto *pane = session_.focusedPane()) {
      session_.closePane(identity == 0 ? pane->id : identity);
    }
  } else if (action == Action::fullscreen) {
    session_.toggleFullscreen();
  } else {
    return false;
  }

  return true;
}

void Application::executeWindowAction(Action action) {
  if (action == Action::detach) {
    if (window_ != nullptr) {
      window_->close();
    }
  } else if (action == Action::toggle_sidebar) {
    session_.setSidebarVisible(!session_.configuration().sidebar_visible);
    emit configurationChanged();
  } else if (action == Action::toggle_workspace_list) {
    session_.setWorkspaceListCollapsed(!session_.workspaceListCollapsed());
    emit configurationChanged();
  } else if (action == Action::history) {
    history_filters_ = {.author = session_.configuration().history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human};
    session_.inspectHistory(false);
    showDialog(QStringLiteral("history"));
    searchHistory({});
  } else if (action == Action::palette || action == Action::goto_picker) {
    showPalette(action == Action::palette ? PaletteMode::actions : PaletteMode::navigate);
  } else if (action == Action::path_picker) {
    showPathPicker();
  } else if (action == Action::suggest_command) {
    showPalette(PaletteMode::suggest);
  } else if (action == Action::new_workspace || action == Action::rename_tab || action == Action::rename_workspace) {
    showDialog(dialogName(action));
  } else if (action == Action::copy_mode) {
    if (dialog_.isEmpty()) {
      static_cast<void>(session_.enterCopyMode());
      emit stateChanged();
      if (session_.copyMode().state()) {
        emit terminalChanged(session_.copyMode().state().value().pane_id);
      }
    }
  } else if (action == Action::cancel) {
    cancelCurrentInteraction();
  }
}

void Application::cancelCurrentInteraction() {
  session_.invalidateSuggestion();
  if (restorePaletteParent()) {
    return;
  }

  const auto &copy = session_.copyMode().state();
  if (dialog_.isEmpty() && copy && !copy->pointer) {
    const auto pane_id = copy->pane_id;
    session_.leaveCopyMode();
    emit terminalChanged(pane_id);
    emit stateChanged();
  }

  showDialog({});
}

void Application::setSidebarWidth(qreal width) {
  session_.setSidebarWidth(static_cast<float>(std::clamp(width, qreal{Configuration::minimum_sidebar_width}, qreal{Configuration::maximum_sidebar_width})));
  emit configurationChanged();
}

void Application::synchronizeFontMetrics() {
  const auto scale = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto resolved = resolveFont(scale);
  const auto &font = resolved.font;
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
    session_.invalidateView();
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

void Application::searchHistory(const QString &query) {
  const auto measured = Utf16Prefix::fit(QStringView{query}, HistorySearch::maximum_query_bytes);
  history_query_ = query.first(static_cast<qsizetype>(measured.units));
  if (!history_query_.isValidUtf16()) {
    history_query_ = QString::fromUtf8(history_query_.toUtf8());
  }

  history_timer_.start();
  emit historyChanged();

  if (measured.bytes < measured.requested_bytes) {
    reportHistoryQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
  }
}

void Application::input(std::uint64_t pane_id, const QByteArray &bytes, PaneInputSource source) {
  const auto &copy = session_.copyMode().state();
  const auto previous = copy && copy->pointer ? copy->pane_id : 0;
  try {
    session_.input(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())}, source);
  } catch (const std::exception &error) {
    fail(error);
  }

  if (previous != 0 && !session_.copyMode().state()) {
    publishCopyChange(previous);
  }
}

void Application::paste(std::uint64_t pane_id, const QString &text) {
  try {
    const auto bytes = text.toUtf8();
    session_.paste(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
  } catch (const std::exception &error) {
    fail(error);
  }
}

void Application::resize(std::uint64_t pane_id, TerminalSize size) {
  try {
    session_.resize(pane_id, size);
  } catch (const std::exception &error) {
    fail(error);
  }
}

void Application::scroll(PaneScrollDelta delta) {
  try {
    session_.scroll(delta);
  } catch (const std::exception &error) {
    fail(error);
  }
}

void Application::showDialog(const QString &kind, const QString &text) {
  if (kind != QLatin1StringView("palette")) {
    palette_parent_.reset();
    palette_editor_restore_ = {};
  }

  if (dialog_ == QLatin1StringView("paths") && kind != QLatin1StringView("paths")) {
    session_.closePathPicker();
  }

  key_bindings_.cancelSequence();
  ++dialog_generation_;
  presented_history_.reset();
  presented_history_surface_ = {};
  dialog_ = kind;
  dialog_text_ = text;
  emit dialogChanged();
}

void Application::fail(const std::exception &error) {
  error_ = QString::fromUtf8(error.what());
  emit stateChanged();
}

QVariantMap Application::colors() const {
  return themeColors(session_.configuration());
}

QVariantMap Application::font() const {
  return fontSettings(session_.configuration().font);
}

ResolvedFont Application::resolveFont(qreal scale) {
  return configuration_source_.resolveFont(session_.configuration().font, scale);
}

QVariantMap Application::workspaceContext() const {
  return workspace_context_;
}

bool Application::sidebarVisible() const {
  return session_.configuration().sidebar_visible;
}

qreal Application::sidebarWidth() const {
  return session_.configuration().sidebar_width;
}

bool Application::workspaceListCollapsed() const {
  return session_.workspaceListCollapsed();
}

qreal Application::windowControls() const {
  return window_ == nullptr ? 0 : platform::windowControls(*window_);
}

QString Application::dialog() const {
  return dialog_;
}

QString Application::dialogText() const {
  return dialog_text_;
}

bool Application::connected() const {
  return connection_.ready();
}

QString Application::title() const {
  const auto title = session_.windowTitle({hostname_.constData(), static_cast<std::size_t>(hostname_.size())});

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
  return metricsRecord(session_.hostMetrics());
}

QString Application::tlsBadgeColor() const {
  const auto &proxy = session_.proxyStatus();
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
  session_.dismissDiagnostic();
  connection_.dismissError();
  emit stateChanged();
}

QString Application::error() const {
  if (!error_.isEmpty()) {
    return error_;
  }

  return connection_.error().isEmpty() ? toQString(session_.error()) : connection_.error();
}

}
