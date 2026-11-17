#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "application/dependencies.hpp"
#include "application_effects.hpp"
#include "core/terminal_size.hpp"
#include "platform/window.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "terminal/cell_position.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/foundation/fonts/window_font_catalog.hpp"
#include "ui/foundation/input/key_adapter.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/scene/window_animation_clock.hpp"
#include "ui/foundation/timing/deadline_timer.hpp"
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
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <optional>
#include <string_view>

import telar.gui.application;
import telar.gui.machines.picker;
import telar.gui.presentation.history_inspection;
import telar.wire.vocabulary;

namespace telar::gui::qt {

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
        key_bindings_(commands_, store_, copy_, components_, attachments_, terminals_),
        pointer_dispatcher_(display_, memory, store_, tabs_, history_, activity_, attachments_, terminals_),
        status_(store_, copy_, key_bindings_, system::hostName()),
        frames_(memory, store_, display_, tabs_, history_, terminals_, pointer_dispatcher_, status_),
        dialogs_(store_, peek_, machine_prompt_, palette_, paths_, history_, workspace_form_, key_bindings_, pointer_dispatcher_),
        machines_(memory, store_, configuration_source_, effects_, frames_, display_, status_, dialogs_, *this, system::hostName()),
        roster_(store_, machines_, machine_profiles_, display_, dialogs_, notifications_, system::hostName()),
        activity_selection_(store_, activity_, peek_, dialogs_, machines_),
        commands_({
            .store = store_,
            .configuration = configuration_source_,
            .keys = key_bindings_,
            .dialogs = dialogs_,
            .machines = machines_,
            .machine_profiles = machine_profiles_,
            .activity_selection = activity_selection_,
            .display = display_,
            .status = status_,
            .palette = palette_,
            .history = history_,
            .workspace_form = workspace_form_,
            .copy = copy_,
            .prompt = prompt_,
            .terminals = terminals_,
            .components = components_,
            .attachments = attachments_,
            .plugins = plugins_,
            .notifications = notifications_,
            .links = links_,
            .element_slots = element_slots_,
            .host = *this,
        }) {
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
    palette_.setCommands(commands_.list());

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
      palette_.setCommands(commands_.list());
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
      commands_.execute(window_actions::Action::machine_picker);
    });
    connect(&machine_chrome_, &MachineChromeController::selectRequested, this, [this](MachineToken token) {
      commands_.interact([this, token] {
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
    connect(&commands_, &WindowCommands::notified, this, &ApplicationController::notification);
    connect(&links_, &LinksController::notificationPublished, &notifications_, &NotificationsController::refresh);
    connect(&tabs_, &TabsController::selectRequested, this, [this](qulonglong tab_id) {
      commands_.execute(window_actions::Action::select_tab, QString::number(tab_id));
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
    commands_.interrupt();
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

  void ApplicationController::closeWindow() {
    if (window_ != nullptr) {
      window_->close();
    }
  }

  int ApplicationController::controlModifier() {
    return static_cast<int>(NativeKeyAdapter::control_modifier);
  }

  int ApplicationController::superModifier() {
    return static_cast<int>(NativeKeyAdapter::super_modifier);
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

  application::Pane<Memory>* ApplicationController::pane(std::uint64_t identity) const noexcept {
    return session().findPane(identity);
  }

  const Configuration& ApplicationController::configuration() const noexcept {
    return session().configuration();
  }

  void ApplicationController::consume(MachineClient& client, QByteArrayView payload) {
    try {
      const bool active = client.key.machine.slot == store_.machines().active();
      const WindowCommands::HostCommands handler{commands_, active};
      const auto notification_revision = client.session.notificationRevision();
      const auto graphics_revision = application::terminal::graphics::recoveryRevision(client.session);
      const auto change = client.session.consume(byteView({payload.data(), static_cast<std::size_t>(payload.size())}), handler);
      // Terminal frames and documents reach their panes directly, and are the bulk of the
      // traffic; every other change may move what the projections read.
      if (change != application::Change::none && change != application::Change::terminal && change != application::Change::document) {
        store_.touch();
      }
      if (change == application::Change::stopped || change == application::Change::closed) {
        client.connection.finishSession();
        if (change == application::Change::closed) {
          client.session.disconnected();
        }
      }

      static_cast<void>(client.session.settlePresentation());
      machines_.summarize(client.key);
      if (active && client.key.machine.slot != Machines::local_slot && (change == application::Change::stopped || change == application::Change::closed)) {
        machines_.select(store_.machines().token(Machines::local_slot));
        return;
      }

      activity_selection_.settle();
      if (!active) {
        if (change == application::Change::model || change == application::Change::stopped) {
          refresh_timer_.start();
        }

        return;
      }

      if (notification_revision != session().notificationRevision()) {
        notifications_.refresh();
      }

      if (graphics_revision != application::terminal::graphics::recoveryRevision(session())) {
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

  void ApplicationController::presentChange(application::Change change) {
    switch (change) {
    case application::Change::sidebar:
      display_.publish();
      refresh();
      break;
    case application::Change::terminal:
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
    case application::Change::paths:
      paths_.refresh();
      break;
    case application::Change::suggestion:
      palette_.publish();
      break;
    case application::Change::peek:
      peek_.synchronize();
      status_.publish();
      break;
    case application::Change::document:
      documents_.publish(session().changedPane());
      // Inline documents take rows of the view, or give them back.
      emit terminals_.terminalChanged(session().changedPane());
      frames_.request();
      break;
    case application::Change::copy_mode:
      copy_.publishSearch();
      status_.publish();
      if (const auto& copy = application::terminal::copy_mode::view(session()).state()) {
        emit terminals_.terminalChanged(copy->pane_id);
      }

      break;
    case application::Change::clipboard:
      QGuiApplication::clipboard()->setText(toQString(session().clipboard()));
      break;
    case application::Change::history:
      // The store was touched when the payload arrived; the dialog synchronizes on its flush.
      break;
    case application::Change::notification:
      break;
    case application::Change::metrics:
      status_.publishMetrics();
      break;
    case application::Change::model:
      if (!refresh_timer_.isActive()) {
        refresh_timer_.start();
      }

      break;
    case application::Change::stopped:
    case application::Change::closed:
      if (window_ != nullptr) {
        window_->close();
      }

      break;
    case application::Change::none:
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

  void ApplicationController::refreshElementBars() {
    components_.refreshElementBars({
        {QStringLiteral("workspace"), workspaces_.context().value(QStringLiteral("name"))},
        {QStringLiteral("machine"), machines_.context().value(QStringLiteral("label"))},
        {QStringLiteral("tab_count"), tabs_.count()},
        {QStringLiteral("sidebar_visible"), display_.sidebarVisible()},
    });
  }

  void ApplicationController::scheduleGraphicsRecovery() {
    scheduleDeadline(graphics_resume_timer_, session().ready() ? application::terminal::graphics::resumeDeadline(session()) : std::nullopt, system::AwakeClock::nowNanoseconds());
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

  void ApplicationController::interacted() {
    // Exceptions stay on this side of the signal that delivered the interaction.
    try {
      prompt_.publishWrite();
      // A controller's interaction may have published a notification, such as a reached limit.
      notifications_.present();

      refresh();
    } catch (const std::exception& error) {
      commands_.fail(error);
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
