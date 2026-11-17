#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "application/dependencies.hpp"
#include "application_effects.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "platform/window.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/protocol/clients.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "ui/app/chrome/metrics_projection.hpp"
#include "ui/app/chrome/mode_bar/mode_projection.hpp"
#include "ui/app/panes/terminal/scene/window_images.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/foundation/fonts/terminal_font.hpp"
#include "ui/foundation/fonts/window_font_catalog.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/models/tab_leaves.hpp"
#include "ui/foundation/process/launch_arguments.hpp"
#include "ui/foundation/scene/window_animation_clock.hpp"
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
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "platform/window.hpp"

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

    auto dialogFor(window_actions::Action action) -> ApplicationController::Dialog {
      using Dialog = ApplicationController::Dialog;

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

  }

  ApplicationController::ApplicationController(ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        memory_(memory),
        history_(store_),
        configuration_source_(memory),
        display_(store_, configuration_source_),
        machine_profiles_(memory),
        attachments_(store_, memory),
        sound_player_(*this),
        system_notifier_(memory),
        effects_(system_notifier_, sound_player_),
        workspaces_(store_),
        tabs_(store_, element_slots_),
        panes_(store_, element_slots_),
        activity_(store_, element_slots_, memory),
        sidebar_(store_, workspaces_, activity_),
        palette_(store_, PaletteAction{.value = static_cast<int>(window_actions::Action::suggest_command)}),
        paths_(store_),
        machine_prompt_(store_, machine_profiles_),
        machine_chrome_(store_),
        peek_(store_),
        prompt_(store_),
        documents_(store_),
        link_status_(store_),
        links_(store_),
        copy_(store_),
        terminals_(store_, copy_, prompt_, *this, memory),
        notifications_(store_),
        components_(store_, configuration_source_, element_slots_, memory),
        plugins_(store_, configuration_source_, memory),
        workspace_form_(store_),
        key_bindings_(*this, store_, copy_, components_, attachments_, terminals_),
        pointer_dispatcher_(display_, memory, store_, tabs_, history_, activity_, attachments_, terminals_),
        status_(store_, copy_, key_bindings_, platform::hostName()),
        frames_(memory, store_, display_, tabs_, history_, terminals_, pointer_dispatcher_, status_),
        dialogs_(store_, peek_, machine_prompt_, palette_, paths_, history_, workspace_form_, key_bindings_, pointer_dispatcher_),
        machines_(memory, store_, configuration_source_, effects_, frames_, display_, status_, dialogs_, *this, platform::hostName()),
        roster_(store_, machines_, machine_profiles_, display_, dialogs_, notifications_, platform::hostName()),
        activity_selection_(store_, activity_, peek_, dialogs_, machines_) {
    composeWindowAnimation();
    machines_.initialize();
    connect(&machines_, &MachinesCoordinator::listChanged, &palette_, &PaletteController::refreshMachines);
    initializeAttachments();
    initializeComponents();
    initializeElements();
    initializePicks();
    initializePalette();
    initializePlugins();
    key_bindings_.configure(configuration_source_.input(), configuration_source_.keymap());
    palette_.setCommands(commands());

    connect(this, &ApplicationController::configurationChanged, &display_, &WindowDisplay::publish);
    connect(&copy_, &CopyController::paneChanged, &terminals_, &TerminalController::terminalChanged);
    connect(&copy_, &CopyController::inputStarted, this, [this] {
      key_bindings_.cancelSequence();
    });
    connect(&copy_, &CopyController::searchRequested, this, [this] {
      dialogs_.show(Dialog::copy_search);
    });
    connect(&copy_, &CopyController::linkRequested, this, [this](qulonglong pane_id, CellPosition cursor) {
      links_.openAt(pane_id, cursor);
    });
    connect(&copy_, &CopyController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });
    connect(&copy_, &CopyController::failed, &status_, &WindowStatus::report);
    connect(&key_bindings_, &KeyBindings::failed, &status_, &WindowStatus::report);
    connect(&pointer_dispatcher_, &PointerDispatcher::failed, &status_, &WindowStatus::report);
    // The search reads the command the dialog's line was opened on.
    connect(&dialogs_, &Dialogs::changed, &copy_, &CopyController::publishSearch);
    // The prefix mode lists the keymap's hints.
    connect(this, &ApplicationController::configurationChanged, &status_, &WindowStatus::modeChanged);
    connect(this, &ApplicationController::configurationChanged, this, [this] {
      palette_.setCommands(commands());
    });
    connect(&store_, &Store::interacted, this, &ApplicationController::interacted);
    connect(&store_, &Store::changed, this, &ApplicationController::synchronize);
    // After the workbench geometry, which the dialogs measured from the display are placed in.
    connect(&display_, &WindowDisplay::changed, this, &ApplicationController::measureDisplay);
    connect(&display_, &WindowDisplay::changed, this, [this] {
      history_.setMetrics(display_.historyMetrics());
    });
    connect(&history_, &HistoryController::submitted, this, [this] {
      status_.clear();
    });
    connect(&history_, &HistoryController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });
    connect(&history_, &HistoryController::failed, &status_, &WindowStatus::report);
    connect(&paths_, &PathPickerController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });
    connect(&paths_, &PathPickerController::failed, &status_, &WindowStatus::report);
    connect(&machine_prompt_, &MachinePromptController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });
    connect(&machines_, &MachinesCoordinator::listChanged, &machine_chrome_, &MachineChromeController::machinesChanged);
    connect(&machine_chrome_, &MachineChromeController::pickerRequested, this, [this] {
      execute(window_actions::Action::machine_picker);
    });
    connect(&machine_chrome_, &MachineChromeController::selectRequested, this, [this](MachineToken token) {
      applyInteraction([this, token] {
        machines_.select(token);
      });
    });
    connect(&peek_, &PeekController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });
    connect(&peek_, &PeekController::failed, &status_, &WindowStatus::report);
    connect(&panes_, &PanesController::failed, &status_, &WindowStatus::report);
    connect(&machines_, &MachinesCoordinator::changed, &link_status_, &LinkStatusController::publish);
    connect(&machines_, &MachinesCoordinator::linkChanged, &link_status_, &LinkStatusController::publish);
    connect(&links_, &LinksController::openingFailed, this, &ApplicationController::notification);
    connect(&links_, &LinksController::notificationPublished, &notifications_, &NotificationsController::refresh);
    connect(&tabs_, &TabsController::selectRequested, this, [this](qulonglong tab_id) {
      execute(window_actions::Action::select_tab, QString::number(tab_id));
      restoreTerminalFocus();
    });
    connect(&documents_, &DocumentsController::measured, this, [this](qulonglong pane_id) {
      emit terminals_.terminalChanged(pane_id);
      frames_.request();
    });
    connect(&machines_, &MachinesCoordinator::changed, &status_, &WindowStatus::publishMetrics);
    connect(&sidebar_, &SidebarController::widthRequested, &display_, &WindowDisplay::setSidebarWidth);

    refresh_timer_.setSingleShot(true);
    initializeNotifications();
    initializeGraphicsRecovery();
    initializePrompt();

    connect(&configuration_source_, &ConfigurationSource::changed, this, [this] {
      status_.clear();
      key_bindings_.configure(configuration_source_.input(), configuration_source_.keymap());
      machines_.configure();
      display_.measureFont();
      publishConfiguration();

      // A reload sets the sidebar back to its configured width, so an automatic one fits again,
      // in the display the published configuration measures.
      sidebar_.refit();
      history_.setMetrics(display_.historyMetrics());
      configureWindow();
      refresh();
    });

    connect(&configuration_source_, &ConfigurationSource::failed, this, [this] {
      status_.report(configuration_source_.error());
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

    connect(&refresh_timer_, &QTimer::timeout, this, &ApplicationController::refresh);
    connect(&machines_, &MachinesCoordinator::listChanged, &sidebar_, &SidebarController::publishMachines);
    connect(&machines_, &MachinesCoordinator::listChanged, this, [this] {
      if (!refresh_timer_.isActive()) {
        refresh_timer_.start();
      }
    });

    initializeTerminals();
    display_.layoutWorkbench();
    measureDisplay();
  }

  void ApplicationController::runtimeDisconnected(MachineClient& client) {
    activity_selection_.drop(client.key);

    machines_.markDisconnected(client);
    if (client.key.machine.slot != store_.machines().active()) {
      return;
    }

    if (store_.dialog().kind == Dialog::palette) {
      palette_.publish();
    }

    if (store_.dialog().kind == Dialog::paths || store_.dialog().kind == Dialog::peek) {
      dialogs_.show(Dialog::none);
    }

    scheduleGraphicsRecovery();
    status_.publishMetrics();
    refresh_timer_.start();
  }

  GuiSession& ApplicationController::session() noexcept {
    return store_.session();
  }

  const GuiSession& ApplicationController::session() const noexcept {
    return store_.session();
  }

  RuntimeConnection& ApplicationController::connection() noexcept {
    return store_.connection();
  }

  const RuntimeConnection& ApplicationController::connection() const noexcept {
    return store_.connection();
  }

  void ApplicationController::releaseInput() {
    interruptBindings();
    for (const auto& pane : session().panes()) {
      terminals_.releaseInput(pane->id);
    }
  }

  void ApplicationController::forgetView() {
    history_.forget();
    graphics_resume_timer_.stop();
    panes_.forget();
    tabs_.forget();
    workspaces_.forget();
    activity_.forget();
    status_.clear();
    frames_.restart();
  }

  void ApplicationController::attend(MachineClient& client) {
    const auto key = client.key;

    connect(
        &client.connection,
        &RuntimeConnection::payloadReceived,
        this,
        [this, key](QByteArrayView payload) {
          if (auto* source = store_.find(key)) {
            consume(*source, payload);
          }
        },
        Qt::DirectConnection
    );

    connect(
        &client.connection,
        &RuntimeConnection::paneWillDetach,
        this,
        [this, key](qulonglong pane_id) {
          if (store_.find(key) != nullptr && key.machine.slot == store_.machines().active()) {
            terminals_.releaseInput(pane_id);
          }
        },
        Qt::DirectConnection
    );

    connect(&client.connection, &RuntimeConnection::disconnected, this, [this, key] {
      if (auto* source = store_.find(key)) {
        runtimeDisconnected(*source);
      }
    });
  }

  void ApplicationController::dismiss(MachineClient& client) {
    client.connection.disconnect(this);
  }

  void ApplicationController::presentMachine() {
    configureWindow();
    notifications_.refresh();
    refresh();
    restoreTerminalFocus();
  }

  void ApplicationController::soundPlaybackFinished(std::optional<CommandFailure> failure) {
    machines_.soundFinished(failure);
  }

  void ApplicationController::peekActivity(const QString& identity) {
    applyInteraction([&] {
      activity_selection_.select(identity, true);
    });
  }

  void ApplicationController::loadConfiguration(const QString& path, const QString& profile, const QString& theme, const QString& trust_path) {
    configuration_source_.open({.path = path, .profile = profile, .theme = theme, .trust_path = trust_path});
  }

  ApplicationController::~ApplicationController() {
    if (window_ != nullptr) {
      window_->removeEventFilter(this);
      window_->disconnect(this);
    }

    frames_.stop();
    QObject::disconnect(screen_refresh_connection_);
    machines_.shutdown();
  }

  void ApplicationController::setWindow(QQuickWindow& window) {
    if (window_ == &window) {
      return;
    }

    if (store_.dialog().kind == Dialog::peek) {
      dialogs_.show(Dialog::none);
    }

    if (window_ != nullptr) {
      window_->removeEventFilter(this);
      window_->disconnect(this);
    }

    // Keep every chrome action reachable, independent of the desktop's text-only Tab policy.
    QGuiApplication::styleHints()->setTabFocusBehavior(Qt::TabFocusAllControls);

    window_ = &window;
    display_.setWindow(window);
    ++window_generation_;
    peek_.setWindowGeneration(window_generation_);
    activity_selection_.setWindowGeneration(window_generation_);
    notifications_.setWindow(window, window_generation_);
    components_.setWindow(window);
    frames_.setWindow(window, window_generation_);
    history_.setWindow(&window);
    activity_.setWindow(&window);
    sidebar_.setWindow(window);
    machine_chrome_.setWindow(window);
    tabs_.setWindow(window);
    pointer_dispatcher_.presentHistoryActions({});
    key_bindings_.setWindow(window);
    pointer_dispatcher_.setWindow(window);
    window.installEventFilter(this);
    connect(&window, &QWindow::widthChanged, this, &ApplicationController::synchronizeWindowSize);
    connect(&window, &QWindow::heightChanged, this, &ApplicationController::synchronizeWindowSize);
    connect(&window, &QWindow::screenChanged, this, &ApplicationController::synchronizeScreen);
    connect(&window, &QWindow::windowStateChanged, &display_, &WindowDisplay::publish);
    terminals_.setWindow(window);
    frames_.observeFrames(window);
    synchronizeScreen();
    configureWindow();
  }

  void ApplicationController::synchronizeScreen() {
    QObject::disconnect(screen_refresh_connection_);
    if (window_ != nullptr && window_->screen() != nullptr) {
      screen_refresh_connection_ = connect(window_->screen(), &QScreen::refreshRateChanged, this, &ApplicationController::synchronizeCadence);
    }

    synchronizeDisplay();
    synchronizeCadence();
  }

  void ApplicationController::synchronizeDisplay() {
    try {
      display_.measureFont();
      if (window_ != nullptr) {
        display_.resize(window_->width(), window_->height());
      }

      display_.publish();
      refreshPanes();
    } catch (const std::exception& error) {
      status_.fail(error);
    }
  }

  bool ApplicationController::eventFilter(QObject* watched, QEvent* event) {
    if (watched == window_ && frames_.pacing() && event->type() == QEvent::UpdateRequest) {
      return frames_.defer();
    }

    if (watched == window_ && window_ != nullptr && event->type() == QEvent::DevicePixelRatioChange && window_->effectiveDevicePixelRatio() != display_.grid().scale) {
      synchronizeDisplay();
    }

    return false;
  }

  void ApplicationController::synchronizeCadence() {
    if (window_ == nullptr || window_->screen() == nullptr) {
      return;
    }

    const auto rate = window_->screen()->refreshRate();
    if (std::isfinite(rate) && rate > 0) {
      const auto fps = static_cast<std::uint16_t>(std::clamp(std::round(rate), qreal{Configuration::minimum_fps}, qreal{Configuration::maximum_fps}));

      machines_.setDisplayRefresh(fps);
    }

    frames_.configure();
  }

  void ApplicationController::configureWindow() {
    if (window_ == nullptr) {
      return;
    }

    const auto& configuration = session().configuration();

    WindowAnimationClock::forWindow(*window_).setMaximumFrameRate(configuration.max_fps == 0 ? std::nullopt : std::optional{configuration.max_fps});
    frames_.configure();
    const QPointer<ApplicationController> lifetime{this};
    const auto owner = window_;

    WindowFontCatalog::forWindow(*owner).configure(configuration.font);
    if (lifetime.isNull() || owner.isNull() || window_ != owner) {
      return;
    }

    platform::configureWindow(*window_, {.titlebar = configuration.titlebar.value_or(platform::defaultTitlebar()), .navigation_height = display_.metrics(window_->effectiveDevicePixelRatio()).chrome.top_bar / static_cast<float>(window_->effectiveDevicePixelRatio()), .background_opacity = configuration.opacity.minimum(configuration.background_opacity), .background_blur = configuration.background_blur});
    display_.publish();
  }

  Pane<Memory>* ApplicationController::pane(std::uint64_t identity) const noexcept {
    return session().findPane(identity);
  }

  const Configuration& ApplicationController::configuration() const noexcept {
    return session().configuration();
  }

  void ApplicationController::consume(MachineClient& client, QByteArrayView payload) {
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
      machines_.summarize(client.key);
      if (active && client.key.machine.slot != Machines::local_slot && (change == Change::stopped || change == Change::closed)) {
        machines_.select(store_.machines().token(Machines::local_slot));
        return;
      }

      activity_selection_.settle();
      if (!active) {
        if (change == Change::model || change == Change::stopped) {
          refresh_timer_.start();
        }

        return;
      }

      if (notification_revision != session().notificationRevision()) {
        notifications_.refresh();
      }

      if (graphics_revision != session().graphicsRecoveryRevision()) {
        refreshPanes();
        scheduleGraphicsRecovery();
      }

      presentChange(change);
    } catch (const std::exception& error) {
      if (client.key.machine.slot == store_.machines().active()) {
        status_.fail(error);
        store_.touch();
      } else {
        client.connection.recover(error.what());
      }
    }
  }

  void ApplicationController::presentChange(Change change) {
    switch (change) {
    case Change::sidebar:
      display_.publish();
      refresh();
      break;
    case Change::terminal:
      attachments_.reconcileFrame(session().changedPane());
      emit terminals_.terminalChanged(session().changedPane());
      if (session().takeChromeChange() && !refresh_timer_.isActive()) {
        refresh_timer_.start();
      }

      if (store_.dialog().kind == Dialog::paths) {
        paths_.publishGeometry();
      }

      frames_.request();
      break;
    case Change::paths:
      paths_.refresh();
      break;
    case Change::suggestion:
      palette_.publish();
      break;
    case Change::peek:
      peek_.synchronize();
      status_.publish();
      break;
    case Change::document:
      documents_.publish(session().changedPane());
      // Inline documents take rows of the view, or give them back.
      emit terminals_.terminalChanged(session().changedPane());
      frames_.request();
      break;
    case Change::copy_mode:
      copy_.publishSearch();
      status_.publish();
      if (const auto& copy = session().copyMode().state()) {
        emit terminals_.terminalChanged(copy->pane_id);
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
      status_.publishMetrics();
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

  void ApplicationController::HostCommands::operator()(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) const {
    if (!active) {
      UnsupportedClientCommand{}(message, reply);
    } else if (!answerConfiguration(application, message, reply)) {
      application.executeHostCommand(message, reply);
    }
  }

  bool ApplicationController::answerConfiguration(tbc::view<ApplicationController&, tbc::lt::a> application, const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply) {
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

  void ApplicationController::executeHostCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    switch (message.action) {
    case ClientAction::plugin_enable:
    case ClientAction::plugin_disable:
      configuration_source_.setPluginEnabled(message, message.action == ClientAction::plugin_enable);
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::plugin_run:
      plugins_.start(configuration_source_.pluginInvocation(message, bindingContext()));
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

      const auto* focused = session().focusedPane();
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

  void ApplicationController::measureDisplay() {
    const auto display = display_.metrics(display_.density());

    palette_.setDisplay(display);
    paths_.setDisplay(display);
    machine_prompt_.setDisplay(display);
    peek_.setDisplay(display);
    link_status_.setDisplay(display);
    attachments_.setDisplay(display);
    notifications_.setDisplay(display, display_.grid());
    machine_chrome_.setDisplay(display);
    sidebar_.setDisplay(display);
    terminals_.setChromeRatio(display_.chromeRatio());
  }

  void ApplicationController::refresh() {
    synchronize();
    peek_.synchronize();
    refreshElementBars();
    if (store_.dialog().kind == Dialog::paths) {
      paths_.publishGeometry();
    }

    scheduleGraphicsRecovery();
    status_.publish();
    attachments_.publishGeometry();
    notifications_.publishView();
    emit terminals_.refreshed();
    frames_.reconsider();
  }

  void ApplicationController::refreshPanes() {
    attachments_.synchronize();
    panes_.setScale(display_.grid().scale);
    panes_.synchronize();
  }

  void ApplicationController::execute(window_actions::Action action, const QString& target) {
    key_bindings_.cancelSequence();
    applyInteraction([&] {
      if (action != window_actions::Action::copy_mode && (action != window_actions::Action::cancel || store_.dialog().kind == Dialog::none)) {
        copy_.leaveKeyboard();
      }

      if (!executeNavigation(action, target) && !executePane(action, target.toULongLong())) {
        executeWindowAction(action);
      }
    });
  }

  void ApplicationController::submitDialog(const QVariantMap& input) {
    applyInteraction([&] {
      const auto name = input.value(QStringLiteral("text")).toString().toUtf8();
      const auto path = input.value(QStringLiteral("path")).toString().toUtf8();
      const std::string_view text{name.constData(), static_cast<std::size_t>(name.size())};

      if (store_.dialog().kind == Dialog::new_workspace) {
        if (!workspace_form_.submit(input)) {
          return;
        }
      } else if (store_.dialog().kind == Dialog::rename_tab) {
        session().renameTab(text);
      } else if (store_.dialog().kind == Dialog::rename_workspace) {
        session().renameWorkspace(text);
      } else if (store_.dialog().kind == Dialog::copy_search) {
        session().searchCopy(text);
      }

      dialogs_.show(Dialog::none);
    });
  }

  void ApplicationController::interacted() {
    // Exceptions stay on this side of the signal that delivered the interaction.
    try {
      prompt_.publishWrite();
      // A controller's interaction may have published a notification, such as a reached limit.
      notifications_.present();

      refresh();
    } catch (const std::exception& error) {
      interactionFailed(error);
    }
  }

  void ApplicationController::synchronize() {
    tabs_.synchronizeStrip();
    workspaces_.synchronize();
    tabs_.synchronize();
    const auto activity_rebuilds = activity_.rebuilds();
    activity_.synchronize();
    if (activity_.rebuilds() != activity_rebuilds) {
      // The sidebar's natural width follows the widest card.
      sidebar_.fitWhenReady();
    }

    refreshPanes();
    history_.synchronize();
    palette_.synchronize();
  }

  void ApplicationController::interactionFailed(const std::exception& error) {
    if (store_.dialog().kind == Dialog::history) {
      history_.fail(error);
    } else {
      status_.fail(error);
    }
  }

  bool ApplicationController::executeNavigation(window_actions::Action action, const QString& target) {
    const auto identity = target.toULongLong();

    if (action == window_actions::Action::new_tab) {
      session().createTab();
    } else if (action == window_actions::Action::select_tab) {
      if (const auto* active = session().activeTab()) {
        session().selectTab({.workspace = active->location.workspace, .tab_id = identity});
      }
    } else if (action == window_actions::Action::select_tab_index) {
      session().selectTabIndex(static_cast<std::size_t>(identity));
    } else if (action == window_actions::Action::next_tab || action == window_actions::Action::previous_tab) {
      session().selectTabOffset(action == window_actions::Action::next_tab ? 1 : -1);
    } else if (action == window_actions::Action::move_tab_next || action == window_actions::Action::move_tab_previous) {
      session().moveTab(action == window_actions::Action::move_tab_next ? TabMoveDirection::next : TabMoveDirection::previous);
    } else if (action == window_actions::Action::close_tab) {
      if (const auto* active = session().activeTab()) {
        session().closeTab({.workspace = active->location.workspace, .tab_id = identity == 0 ? active->location.tab_id : identity});
      }
    } else if (action == window_actions::Action::select_workspace) {
      session().selectWorkspace(parseLocation(target));
    } else if (action == window_actions::Action::leave_worktree) {
      session().leaveWorktree();
    } else if (action == window_actions::Action::forget_gone_worktrees) {
      session().forgetGoneWorktrees();
    } else if (action == window_actions::Action::select_agent) {
      activity_selection_.select(target);
    } else {
      return false;
    }

    return true;
  }

  bool ApplicationController::executePane(window_actions::Action action, std::uint64_t identity) {
    if (action == window_actions::Action::focus_left || action == window_actions::Action::focus_right || action == window_actions::Action::focus_up || action == window_actions::Action::focus_down) {
      session().focusDirection(paneDirection(action));
    } else if (action == window_actions::Action::resize_left || action == window_actions::Action::resize_right || action == window_actions::Action::resize_up || action == window_actions::Action::resize_down) {
      session().resizeDirection(paneDirection(action));
    } else if (action == window_actions::Action::focus_pane) {
      session().focusPane(identity);
    } else if (action == window_actions::Action::split_horizontal) {
      session().split(ClientLayoutAxis::horizontal);
    } else if (action == window_actions::Action::split_vertical) {
      session().split(ClientLayoutAxis::vertical);
    } else if (action == window_actions::Action::close_pane) {
      if (const auto* pane = session().focusedPane()) {
        session().closePane(identity == 0 ? pane->id : identity);
      }
    } else if (action == window_actions::Action::fullscreen) {
      session().toggleFullscreen();
    } else {
      return false;
    }

    return true;
  }

  void ApplicationController::executeWindowAction(window_actions::Action action) {
    if (executeMachineAction(action)) {
      return;
    }

    if (action == window_actions::Action::detach) {
      if (window_ != nullptr) {
        window_->close();
      }
    } else if (action == window_actions::Action::toggle_sidebar) {
      session().setSidebarVisible(!session().configuration().sidebar_visible);
      display_.publish();
    } else if (action == window_actions::Action::toggle_workspace_list) {
      session().setWorkspaceListCollapsed(!session().workspaceListCollapsed());
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
      if (store_.dialog().kind == Dialog::none && session().enterBlocks()) {
        prompt_.publish(session().changedPane());
        emit terminals_.terminalChanged(session().changedPane());
      } else if (store_.dialog().kind == Dialog::none) {
        static_cast<void>(session().enterCopyMode());
        status_.publish();
        if (const auto& copy = session().copyMode().state()) {
          emit terminals_.terminalChanged(copy->pane_id);
        }
      }
    } else if (action == window_actions::Action::cancel) {
      cancelCurrentInteraction();
    }
  }

  void ApplicationController::cancelCurrentInteraction() {
    session().invalidateSuggestion();
    if (palette_.restoreParent()) {
      return;
    }

    const auto& copy = session().copyMode().state();
    if (store_.dialog().kind == Dialog::none && copy && !copy->pointer) {
      const auto pane_id = copy->pane_id;

      session().leaveCopyMode();
      emit terminals_.terminalChanged(pane_id);
      status_.publish();
    }

    dialogs_.show(Dialog::none);
  }

  void ApplicationController::synchronizeWindowSize() {
    if (window_ != nullptr && display_.resize(window_->width(), window_->height())) {
      display_.publish();
      refreshPanes();
    }
  }

  void ApplicationController::restoreTerminalFocus() {
    const auto* pane = session().focusedPane();
    auto* const terminal = pane != nullptr ? terminals_.terminal(pane->id) : nullptr;
    if (terminal != nullptr && terminal->isVisible() && store_.dialog().kind == Dialog::none) {
      terminal->forceActiveFocus(Qt::OtherFocusReason);
    }
  }

  AttachmentsController* ApplicationController::attachments() noexcept {
    return &attachments_;
  }

  void ApplicationController::initializeAttachments() {
    connect(&attachments_, &AttachmentsController::changed, this, [this] {
      refresh_timer_.start();
    });
    // The modal takes the keyboard and the pointer from the panes while it is open.
    connect(&attachments_, &AttachmentsController::modalChanged, this, [this](bool open) {
      if (open) {
        components_.closePick();
        components_.closePanel();
        interruptBindings();
        for (const auto& pane : session().panes()) {
          terminals_.releaseInput(pane->id);
        }
      } else {
        restoreTerminalFocus();
      }
    });
    connect(&attachments_, &AttachmentsController::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::publishConfiguration() {
    // Qt notifies QML bindings before any connected slot, so the cache is dropped before the
    // signal rather than in a slot of it.
    colors_.reset();
    font_.reset();
    emit configurationChanged();
  }

  // Each pane delegate reads the theme a score of times; it is built once per configuration.
  QVariantMap ApplicationController::colors() const {
    if (!colors_) {
      colors_ = themeColors(session().configuration());
    }

    return *colors_;
  }

  QVariantMap ApplicationController::font() const {
    if (!font_) {
      font_ = fontSettings(session().configuration().font);
    }

    return *font_;
  }

  ResolvedFont ApplicationController::resolveFont(qreal scale) {
    return display_.resolveFont(scale);
  }

}
