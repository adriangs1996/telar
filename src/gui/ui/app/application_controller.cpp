#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "application_effects.hpp"
#include "platform/window.hpp"
#include "telar_base/memory/allocator.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/kit/fonts/window_font_catalog.hpp"
#include "ui/kit/input/key_adapter.hpp"
#include "ui/kit/machines/machine_client.hpp"
#include "ui/kit/models/projection.hpp"
#include "ui/kit/scene/window_animation_clock.hpp"
#include "ui/kit/timing/deadline_timer.hpp"
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
#include <functional>
#include <memory>
#include <optional>
#include <string_view>

import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.gui.foundation.core;

namespace telar::gui::qt {

  namespace {

    // The side of the explorer a key that moves the focus between panes names.
    constexpr application::explorer::Side explorerSide(window_actions::Action action) noexcept {
      using application::explorer::Side;

      if (action == window_actions::Action::focus_left) {
        return Side::left;
      }

      if (action == window_actions::Action::focus_right) {
        return Side::right;
      }

      return action == window_actions::Action::focus_up ? Side::up : Side::down;
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
        machine_wizard_(store_),
        machine_chrome_(store_),
        peek_(store_),
        monitor_(store_),
        explorer_(store_, memory),
        theme_picker_(configuration_source_),
        prompt_(store_, memory),
        documents_(store_),
        link_status_(store_),
        links_(store_),
        copy_(store_),
        terminals_({
            .store = store_,
            .copy = copy_,
            .prompt = prompt_,
            .host = *this,
            .memory = memory,
        }),
        editors_({
            .store = store_,
            .host = *this,
        }),
        notifications_(store_),
        components_(store_, configuration_source_, element_slots_, memory),
        plugins_(store_, configuration_source_, memory),
        workspace_form_(store_),
        key_bindings_({
            .commands = commands_,
            .store = store_,
            .copy = copy_,
            .components = components_,
            .attachments = attachments_,
            .terminals = terminals_,
        }),
        pointer_dispatcher_({
            .display = display_,
            .memory = memory,
            .store = store_,
            .tabs = tabs_,
            .history = history_,
            .activity = activity_,
            .attachments = attachments_,
            .terminals = terminals_,
        }),
        status_(store_, copy_, key_bindings_, system::hostName()),
        frames_({
            .memory = memory,
            .store = store_,
            .display = display_,
            .tabs = tabs_,
            .history = history_,
            .terminals = terminals_,
            .pointers = pointer_dispatcher_,
            .status = status_,
        }),
        dialogs_({
            .store = store_,
            .peek = peek_,
            .machine_prompt = machine_prompt_,
            .machine_wizard = machine_wizard_,
            .palette = palette_,
            .paths = paths_,
            .history = history_,
            .workspace_form = workspace_form_,
            .keys = key_bindings_,
            .pointers = pointer_dispatcher_,
        }),
        machines_({
                      .memory = memory,
                      .store = store_,
                      .configuration = configuration_source_,
                      .desktop = effects_,
                      .frames = frames_,
                      .display = display_,
                      .status = status_,
                      .dialogs = dialogs_,
                      .host = *this,
                  },
            system::hostName()),
        roster_({
                    .store = store_,
                    .machines = machines_,
                    .profiles = machine_profiles_,
                    .display = display_,
                    .dialogs = dialogs_,
                    .notifications = notifications_,
                },
            system::hostName()),
        activity_selection_({
            .store = store_,
            .activity = activity_,
            .peek = peek_,
            .dialogs = dialogs_,
            .machines = machines_,
        }),
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
    initializeCopy();
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

    initializeOverlays();
    initializeMachineChrome();
    initializePeekAndMonitor();
    initializeThemePicker();
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
    initializeConfigurationSource();
    connect(&refresh_timer_, &QTimer::timeout, this, &ApplicationController::refresh);
    connect(&machines_, &MachinesCoordinator::listChanged, this, [this] {
      if (!refresh_timer_.isActive()) {
        refresh_timer_.start();
      }
    });

    initializeTerminals();
    display_.layoutWorkbench();
    measureDisplay();
  }

  void ApplicationController::initializeCopy() {
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
  }

  void ApplicationController::initializeOverlays() {
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

    connect(&machine_wizard_, &MachineWizardController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });

    connect(&machine_wizard_, &MachineWizardController::machineOpened, this, [this](const QString& label) {
      const auto bytes = label.toUtf8();
      const std::string_view wanted{bytes.constData(), static_cast<std::size_t>(bytes.size())};
      const auto rows = store_.machines().rows();

      // The profile the wizard saved reaches the window on the next read of machines.json.
      for (std::size_t slot = 0; slot < rows.size(); ++slot) {
        if (rows[slot].label.view() == wanted && slot != application::machines::Machines::local_slot) {
          machines_.select(store_.machines().token(static_cast<application::machines::Machines::Slot>(slot)));
        }
      }
    });
  }

  void ApplicationController::initializeMachineChrome() {
    connect(&machines_, &MachinesCoordinator::listChanged, &machine_chrome_, &MachineChromeController::machinesChanged);
    connect(&machine_chrome_, &MachineChromeController::pickerRequested, this, [this] {
      commands_.execute(window_actions::Action::machine_picker);
    });

    connect(&machine_chrome_, &MachineChromeController::selectRequested, this, [this](application::machines::MachineToken token) {
      commands_.interact([this, token] {
        machines_.select(token);
      });
    });
  }

  void ApplicationController::settleExplorer() {
    const bool keys = explorer_.showing() && explorer_.focused();

    // It takes the keys of the panes while it has the focus, as a dialog does.
    if (keys && store_.dialog().kind == Dialog::none) {
      dialogs_.show(Dialog::explorer);
    } else if (!keys && store_.dialog().kind == Dialog::explorer) {
      dialogs_.show(Dialog::none);
    }
  }

  void ApplicationController::yieldExplorer() {
    // Another dialog took the explorer's place: over the panes it closes. As a pane it stays,
    // and has the keys again once that dialog is gone, if its pane still has the focus.
    if (store_.dialog().kind == Dialog::explorer || !explorer_.showing() || !explorer_.focused()) {
      return;
    }

    if (!explorer_.pinned()) {
      explorer_.close();
    } else if (store_.dialog().kind == Dialog::none) {
      dialogs_.show(Dialog::explorer);
    }
  }

  void ApplicationController::initializePeekAndMonitor() {
    connect(&peek_, &PeekController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });

    connect(&peek_, &PeekController::failed, &status_, &WindowStatus::report);
    connect(&monitor_, &MonitorController::closeRequested, this, [this] {
      if (store_.dialog().kind == Dialog::monitor) {
        dialogs_.show(Dialog::none);
      }
    });

    connect(&monitor_, &MonitorController::failed, &status_, &WindowStatus::report);

    const auto open_monitor = [this] {
      dialogs_.show(Dialog::monitor);
      monitor_.opened();
    };

    // Showing another machine closes every dialog; the monitor that asked for it opens again on it.
    connect(&monitor_, &MonitorController::machineRequested, this, [this, open_monitor](application::machines::MachineToken token) {
      commands_.interact([this, token, open_monitor] {
        machines_.select(token);
        if (store_.machines().active() == token.slot && store_.dialog().kind == Dialog::none) {
          open_monitor();
        }
      });
    });

    connect(&machines_, &MachinesCoordinator::changed, &monitor_, &MonitorController::machineChanged);

    // The explorer takes the keys of the panes while it shows, as a dialog does.
    connect(&explorer_, &ExplorerController::opened, this, [this] {
      dialogs_.show(Dialog::explorer);
    });

    connect(&explorer_, &ExplorerController::closed, this, [this] {
      if (store_.dialog().kind == Dialog::explorer) {
        dialogs_.show(Dialog::none);
      }
    });

    // As a pane the explorer takes the keys only while its pane has the focus, and a key that
    // moves the focus goes through its own windows before it leaves the pane.
    connect(&explorer_, &ExplorerController::changed, this, &ApplicationController::settleExplorer);
    commands_.setInside([this](window_actions::Action action) {
      return explorer_.takes(explorerSide(action));
    });

    connect(&explorer_, &ExplorerController::failed, &status_, &WindowStatus::report);
    // Files of another machine opened in an editor there: the window shows that machine.
    connect(&explorer_, &ExplorerController::machineRequested, this, [this](application::machines::MachineToken token) {
      commands_.interact([this, token] {
        machines_.select(token);
      });
    });

    connect(&commands_, &WindowCommands::explorerRequested, &explorer_, &ExplorerController::toggle);
    connect(&machines_, &MachinesCoordinator::changed, &explorer_, &ExplorerController::machineChanged);
    // What the panes show moved: a window that follows the focused pane goes where it is.
    connect(&store_, &Store::changed, &explorer_, &ExplorerController::synchronize);
    connect(&dialogs_, &Dialogs::changed, &explorer_, [this] {
      yieldExplorer();
    });

    connect(&commands_, &WindowCommands::monitorRequested, this, [this, open_monitor](window_actions::Action action) {
      const auto showing = store_.dialog().kind == Dialog::monitor;
      if (!showing) {
        open_monitor();
      }

      if (action == window_actions::Action::process_picker) {
        emit monitor_.filterRequested();
      } else if (action != window_actions::Action::monitor && !monitor_.perform(action)) {
        status_.report(QStringLiteral("Select a process in the monitor, then run the action again"));
      }
    });
  }

  void ApplicationController::initializeThemePicker() {
    connect(&commands_, &WindowCommands::themesRequested, this, [this] {
      if (store_.dialog().kind == Dialog::themes) {
        theme_picker_.cancel();
        return;
      }

      dialogs_.show(Dialog::themes);
      theme_picker_.open();
    });

    connect(&theme_picker_, &ThemePickerController::closeRequested, this, [this] {
      if (store_.dialog().kind == Dialog::themes) {
        dialogs_.show(Dialog::none);
      }
    });

    // Another dialog took the picker's place: the window wears its own theme again.
    connect(&dialogs_, &Dialogs::changed, this, [this] {
      if (store_.dialog().kind != Dialog::themes) {
        theme_picker_.dismiss();
      }
    });

    connect(&theme_picker_, &ThemePickerController::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::initializeConfigurationSource() {
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
      for (auto& client : store_.clientsMut().viewMut()) {
        if (client) {
          application::configuration::setTheme(client.getMut().getMut().session, configuration_source_.configuration().theme);
        }
      }

      publishConfiguration();
      refresh();
    });
  }

  void ApplicationController::runtimeDisconnected(application::machines::MachineClientKey key) {
    activity_selection_.drop(key);

    machines_.markDisconnected(key);
    if (key.machine.slot != store_.machines().active()) {
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

  GuiSession& ApplicationController::sessionMut() noexcept {
    return store_.sessionMut();
  }

  const GuiSession& ApplicationController::session() const noexcept {
    return store_.session();
  }

  RuntimeConnection& ApplicationController::connectionMut() noexcept {
    return store_.connectionMut();
  }

  const RuntimeConnection& ApplicationController::connection() const noexcept {
    return store_.connection();
  }

  void ApplicationController::releaseInput() {
    commands_.interrupt();
    for (const auto& pane : session().panes) {
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
          consume(key, payload);
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
      if (store_.findMut(key) != nullptr) {
        runtimeDisconnected(key);
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

  void ApplicationController::soundPlaybackFinished(ds::Option<CommandFailure> failure) {
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

  void ApplicationController::loadConfiguration(const QString& path, const QString& profile, const QString& theme, const QString& trust_path, const QString& theme_choice_path) {
    configuration_source_.open({.path = path, .profile = profile, .theme = theme, .trust_path = trust_path, .theme_choice_path = theme_choice_path});
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

    if (watched == window_ && window_ != nullptr && event->type() == QEvent::DevicePixelRatioChange && std::not_equal_to<>{}(window_->effectiveDevicePixelRatio(), display_.grid().scale)) {
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

    const auto& configuration = session().configuration;

    WindowAnimationClock::forWindow(*window_).setMaximumFrameRate(configuration.max_fps == 0 ? ds::none : ds::Option{configuration.max_fps});
    frames_.configure();
    const QPointer<ApplicationController> lifetime{this};
    const auto owner = window_;

    WindowFontCatalog::forWindow(*owner).configure(configuration.font);
    if (lifetime.isNull() || owner.isNull() || window_ != owner) {
      return;
    }

    platform::configureWindow(*window_, {.titlebar = configuration.titlebar.valueOr(platform::defaultTitlebar()), .navigation_height = display_.metrics(window_->effectiveDevicePixelRatio()).chrome.top_bar / static_cast<float>(window_->effectiveDevicePixelRatio()), .background_opacity = configuration.opacity.minimum(configuration.background_opacity), .background_blur = configuration.background_blur});
    display_.publish();
  }

  const application::Pane<Memory>* ApplicationController::pane(std::uint64_t identity) const noexcept {
    return session().findPane(identity);
  }

  const Configuration& ApplicationController::configuration() const noexcept {
    return session().configuration;
  }

  void ApplicationController::consume(application::machines::MachineClientKey key, QByteArrayView payload) {
    const bool active = key.machine.slot == store_.machines().active();

    try {
      auto* client = store_.findMut(key);
      if (client == nullptr) {
        return;
      }

      WindowCommands::HostCommands handler{commands_, active};
      const auto notification_revision = application::notifications::revision(client->session);
      const auto graphics_revision = application::terminal::graphics::recoveryRevision(client->session);
      const auto change = client->session.consume(byteView({payload.data(), static_cast<std::size_t>(payload.size())}), handler);
      // Terminal frames and documents reach their panes directly, and are the bulk of the
      // traffic; every other change may move what the projections read.
      if (change != application::Change::none && change != application::Change::terminal && change != application::Change::document && change != application::Change::editor) {
        store_.touch();
      }

      if (auto* current = store_.findMut(key)) {
        if (change == application::Change::stopped || change == application::Change::closed) {
          current->connection.finishSession();
        }

        if (change == application::Change::closed) {
          current->session.disconnected();
        }

        static_cast<void>(current->session.settlePresentation());
      }

      machines_.summarize(key);
      if (active && key.machine.slot != application::machines::Machines::local_slot && (change == application::Change::stopped || change == application::Change::closed)) {
        machines_.select(store_.machines().token(application::machines::Machines::local_slot));
        return;
      }

      activity_selection_.settle();
      if (!active) {
        if (change == application::Change::model || change == application::Change::stopped) {
          refresh_timer_.start();
        }

        return;
      }

      if (notification_revision != application::notifications::revision(session())) {
        notifications_.refresh();
      }

      if (graphics_revision != application::terminal::graphics::recoveryRevision(session())) {
        refreshPanes();
        scheduleGraphicsRecovery();
      }

      presentChange(change);
    } catch (const std::exception& error) {
      if (key.machine.slot == store_.machines().active()) {
        status_.fail(error);
        store_.touch();
      } else if (auto* client = store_.findMut(key)) {
        client->connection.recover(error.what());
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
      if (sessionMut().takeChromeChange() && !refresh_timer_.isActive()) {
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
    case application::Change::monitor:
      monitor_.synchronize();
      break;
    case application::Change::explorer:
      explorer_.synchronize();
      break;
    case application::Change::editor:
      // A link the editor opened is opened here, where the person is.
      if (const auto link = application::nvim::takeLink(sessionMut(), session().changedPane())) {
        static_cast<void>(links_.open(*link, session().changedPane()));
      }

      askExplorer(session().changedPane());
      emit editors_.editorChanged(session().changedPane());
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
    case application::Change::notification:
      // History: the store was touched when the payload arrived; the dialog synchronizes on its flush.
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
    components_.setDisplay(display);
    terminals_.setChromeRatio(WindowDisplay::chromeRatio());
  }

  void ApplicationController::refreshElementBars() {
    components_.refreshElementBars({
        {QStringLiteral("workspace"), workspaces_.context().value(QStringLiteral("name"))},
        {QStringLiteral("machine"), machine_chrome_.active().value(QStringLiteral("label"))},
        {QStringLiteral("tab_count"), tabs_.count()},
        {QStringLiteral("sidebar_visible"), display_.sidebarVisible()},
    });
  }

  void ApplicationController::scheduleGraphicsRecovery() {
    scheduleDeadline(graphics_resume_timer_, session().ready() ? application::terminal::graphics::resumeDeadline(session()) : ds::none, system::AwakeClock::nowNanoseconds());
  }

  void ApplicationController::askExplorer(std::uint64_t pane_id) {
    // `:Telar explore`: the explorer shows the file the editor is on, or its directory.
    if (const auto* editor = application::nvim::editor(session(), pane_id); editor != nullptr && editor->explores) {
      const auto* pane = application::findPane(session().panes, pane_id);
      const auto asked = editor->explore.view();
      const auto where = pane == nullptr ? std::string_view{} : pane->cwd.view();
      // Kept apart from the session, which the explorer changes while it reads them.
      const QByteArray path{asked.data(), static_cast<qsizetype>(asked.size())};
      const QByteArray directory{where.data(), static_cast<qsizetype>(where.size())};

      application::nvim::explored(sessionMut(), pane_id);
      explorer_.reveal({path.constData(), static_cast<std::size_t>(path.size())}, {directory.constData(), static_cast<std::size_t>(directory.size())});
    }
  }

  void ApplicationController::refresh() {
    synchronize();
    peek_.synchronize();
    // A pane did something: the explorer asks its machine who touched what, while it shows.
    if (explorer_.showing()) {
      explorer_.synchronize();
    }

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
    cache_.colors.reset();
    cache_.font.reset();
    emit configurationChanged();
  }

  // Each pane delegate reads the theme a score of times; it is built once per configuration.
  QVariantMap ApplicationController::colors() const {
    if (!cache_.colors) {
      cache_.colors = themeColors(session().configuration);
    }

    return *cache_.colors;
  }

  QVariantMap ApplicationController::font() const {
    if (!cache_.font) {
      cache_.font = fontSettings(session().configuration.font);
    }

    return *cache_.font;
  }

  ResolvedFont ApplicationController::resolveFont(qreal scale) {
    return display_.resolveFont(scale);
  }

}
