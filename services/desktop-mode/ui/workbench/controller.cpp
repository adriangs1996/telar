#include "controller.hpp"
#include "idle_work.hpp"
#include "keyboard_router.hpp"
#include "layout.hpp"
#include "native.hpp"
#include "../../log_categories.hpp"
#include "../../session_log.hpp"
#include "runtime_connection.hpp"
#include "terminal_item.hpp"
#include "terminal_clipboard.hpp"
#include "../desktop_ui.hpp"
#include "../lua_surface.hpp"
#include "../services.hpp"
#include "../../desktop_registry.hpp"
#include "../../desktop_session.hpp"
#include "../../runtime_session.hpp"
#include "../../trace.hpp"
#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMetaObject>
#include <QQuickWindow>
#include <QSaveFile>
#include <QScreen>
#include <QTimer>
#include <QUuid>
#include <algorithm>
#include <cmath>
#include <set>
#include <utility>

namespace workbench {
  namespace {
    constexpr int geometry_interval_ms = 1000;
    constexpr int persistence_delay_ms = 300;
    // Outgoing windows wait for the incoming ones' first frame, but never longer than this.
    constexpr int first_frame_timeout_ms = 250;
    constexpr std::uint64_t resource_trace_ticks = 10;
    constexpr std::size_t mebibyte = 1024 * 1024;
    constexpr int default_gap = 8, default_padding = 8, default_header = 34;
    constexpr int maximum_metric = 256;
    // Points between another application's focused window and the ring outlining it, which fits
    // in the default gap.
    constexpr int focus_ring_thickness = 2;
    constexpr qsizetype persistence_limit = 4 * 1024 * 1024;

    std::uint64_t identifier(const QVariant &value) {
      bool valid = false;
      const auto result = value.toString().toULongLong(&valid);

      if (!valid || !result || value.metaType().id() != QMetaType::QString) {
        throw std::runtime_error("IDs must be nonzero decimal strings");
      }

      return result;
    }

    QString paneId(std::uint64_t pane) {
      return QStringLiteral("pane:") + QString::number(pane);
    }

    QString tabKey(std::uint64_t workspace, std::uint64_t tab) {
      return QString::number(workspace) + '/' + QString::number(tab);
    }

    QVariantMap rectangle(const QRectF &value) {
      return {{"x", value.x()},
              {"y", value.y()},
              {"width", value.width()},
              {"height", value.height()}};
    }

    Direction direction(const QString &value) {
      if (value == "left") {
        return Direction::left;
      }

      if (value == "right") {
        return Direction::right;
      }

      if (value == "up") {
        return Direction::up;
      }

      if (value == "down") {
        return Direction::down;
      }

      throw std::runtime_error("Direction must be left, right, up or down");
    }

    double metric(const QVariantMap &options, const char *key, int fallback) {
      bool valid = false;
      const double value = options.value(key, fallback).toDouble(&valid);
      return valid && std::isfinite(value)
                 ? std::clamp(value, 0.0, static_cast<double>(maximum_metric))
                 : fallback;
    }
  } // namespace

  struct Controller::Impl {
    // A view exists for every element of every tab, but its surface is made only when it is
    // presented or prewarmed: making one is the expensive part.
    struct View {
      std::uint64_t pane = 0;
      QString title;
      std::unique_ptr<LuaSurface> surface;
      std::unique_ptr<TerminalItem> terminal;
      // Another application's window, by its window server number.
      std::uint32_t external = 0;
      // The external window waits out of sight, still on its Space, while its tab is not shown.
      bool parked = false;
      QVariantMap configuration;
      QRectF requested, actual, applied;
      std::uint64_t placed_space = 0;
      int shown_order = 0;
      QString error;
      bool visible = false;
      QMetaObject::Connection first_frame;

      ~View() {
        QObject::disconnect(first_frame);
      }

      // Its window is still up, transparent, but the user cannot see it: see hide.
      bool retired() const {
        return surface && !visible && surface->window().isVisible();
      }
    };

    struct Tab {
      std::uint64_t id = 0;
      Layout layout;
      std::map<QString, std::unique_ptr<View>> views;
      std::set<QString> closing;
      bool restored = false;
      Axis next_axis = Axis::horizontal;
      bool focus_new = false;
    };

    struct Workspace {
      std::uint64_t id = 0;
      std::unique_ptr<RuntimeConnection> runtime;
      std::map<std::uint64_t, Tab> tabs;
      std::uint64_t space = 0;
      std::uint32_t display = 0;
      QRectF area;
      double scale = 1;
      bool visible = false;
      // A tab this workbench created, selected once the runtime catalog lists it.
      std::uint64_t created_tab = 0;
    };

    Controller &owner;
    ui::DesktopUi &desktop;
    ui::Services &services;
    // Declared before the workspaces, whose pane windows it routes to, so it outlives them.
    KeyboardRouter keyboard;
    IdleWork prewarming{[this] {
      return prewarm();
    }};
    QTimer update_timer, monitor_timer, save_timer, retire_timer;
    std::uint64_t monitor_ticks = 0;
    // Windows are transparent until their first frame, so a switch keeps the outgoing ones up
    // until every incoming one has drawn.
    std::set<QString> incoming, retiring;
    std::uint64_t runtime_subscription = 0, desktop_subscription = 0, agents_subscription = 0;
    // The done agent last acknowledged, by pane and generation.
    std::optional<std::pair<std::uint64_t, std::uint64_t>> acknowledged;
    std::map<std::uint64_t, Workspace> workspaces;
    // Other applications' windows, as the observer last delivered them.
    native::ForeignWindows foreign;
    // Windows adopted on request although a rule ignores their application.
    std::set<std::uint32_t> adopted;
    // Other applications' windows out of every layout, most recently used first. They belong to
    // no workspace.
    std::vector<std::uint32_t> backstage;

    // A backstage window shown alone over the workspace a display shows, until the user goes
    // back to that workspace's layout.
    struct Takeover {
      std::uint32_t window = 0;
      std::uint64_t space = 0;
      std::uint64_t tab = 0;
    };

    std::map<std::uint32_t, Takeover> takeovers;

    // The backstage switcher, open on one display while the user cycles through the backstage
    // as with Cmd+Tab.
    struct Switcher {
      std::uint32_t display = 0;
      std::size_t selected = 0;
    };

    std::optional<Switcher> switcher;

    // Outlines the focused window of another application; panes draw their own border.
    struct FocusRing {
      std::unique_ptr<LuaSurface> surface;
      QRect frame;
      std::uint64_t space = 0;
      std::uint32_t target = 0;
      bool shown = false;
    };

    FocusRing focus_ring;
    // The focused external window the workbench last brought its tab forward for.
    std::uint32_t followed_focus = 0;
    // Each window the workbench saw but did not adopt, with the reason last logged for it.
    std::map<std::uint32_t, const char *> unadopted;
    // Declared after the workspaces, so it stops before them.
    std::unique_ptr<native::WindowObserver> windows;
    std::map<std::uint64_t, std::function<void()>> subscribers;
    std::uint64_t next_subscription = 1;
    std::uint64_t focused_space = 0;
    std::uint64_t focus_workspace = 0;
    QJsonObject persisted;
    QString persistence_path;
    QString error;
    QVariantMap options;
    QVariantMap notified_state;
    bool changing = false, focus_pending = false;

    Impl(Controller &owner, ui::DesktopUi &desktop)
        : owner(owner),
          desktop(desktop),
          services(desktop.services()) {
      TELAR_TRACE("workbench.start");
      const auto data = QByteArray::fromStdString(services.runtime_socket);
      const auto hash = QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex();

      const auto dir = QString::fromStdString(DesktopRegistry::directory());
      persistence_path = QDir(dir).filePath("workbench-" + QString::fromLatin1(hash) + ".json");

      QFile file(persistence_path);
      if (file.size() <= persistence_limit && file.open(QIODevice::ReadOnly)) {
        persisted = QJsonDocument::fromJson(file.readAll()).object();
      }

      update_timer.setSingleShot(true);
      save_timer.setSingleShot(true);
      save_timer.setInterval(persistence_delay_ms);
      monitor_timer.setInterval(geometry_interval_ms);
      retire_timer.setSingleShot(true);
      retire_timer.setInterval(first_frame_timeout_ms);

      QObject::connect(&update_timer, &QTimer::timeout, &owner, [this] {
        reconcile();
      });

      QObject::connect(&monitor_timer, &QTimer::timeout, &owner, [this] {
        schedule();
        traceResources();
      });

      QObject::connect(&save_timer, &QTimer::timeout, &owner, [this] {
        save();
      });

      QObject::connect(&retire_timer, &QTimer::timeout, &owner, [this] {
        for (const auto &id : incoming) {
          qCInfo(telar_log::workbench)
              << "no first frame from" << id << "in time; hiding the outgoing windows anyway";
        }

        incoming.clear();
        retire();
      });

      runtime_subscription = services.runtime.subscribe([this] {
        schedule();
      });

      agents_subscription = services.runtime.subscribeAgents([this] {
        acknowledgeFocusedAgent();
      });

      // Windows follow Spaces, their displays and the focus; an operation or a status change alone
      // leaves them where they are.
      desktop_subscription = services.desktop.subscribe([this] {
        const auto &changes = services.desktop.changes();
        if (changes.focus || changes.spaces || changes.displays) {
          schedule();
        }
      });

      desktop.changed = [this] {
        schedule();
      };

      windows =
          std::make_unique<native::WindowObserver>(owner, [this](native::ForeignWindows next) {
            foreign = std::move(next);
            schedule();
          });

      monitor_timer.start();
      schedule();
    }

    ~Impl() {
      changing = true;
      services.runtime.unsubscribe(runtime_subscription);
      services.runtime.unsubscribe(agents_subscription);
      services.desktop.unsubscribe(desktop_subscription);
      desktop.changed = {};
      save();
      // Surfaces and their Lua callbacks disappear before transport and controller.
      for (auto &[id, workspace] : workspaces) {
        workspace.runtime->changed = {};
        workspace.runtime->painted = {};
        workspace.tabs.clear();
      }

      focus_ring.surface.reset();
      workspaces.clear();
    }

    void schedule() {
      if (!update_timer.isActive()) {
        update_timer.start(0);
      }
    }

    void notify() {
      TELAR_TRACE("workbench.notify");
      const auto copy = subscribers;
      for (const auto &[id, callback] : copy) {
        if (subscribers.contains(id)) {
          callback();
        }
      }
    }

    Workspace *focusedWorkspace() {
      const auto workspace = services.desktop.focusedWorkspace();
      const auto found = workspace ? workspaces.find(*workspace) : workspaces.end();
      return found == workspaces.end() ? nullptr : &found->second;
    }

    void remember(std::uint64_t workspace_id, std::uint64_t tab_id, const Tab &tab) {
      TELAR_TRACE("workbench.remember");
      if (!tab.restored) {
        return;
      }

      auto state = tab.layout.save();
      QJsonArray views;
      for (const auto &[id, view] : tab.views) {
        if (!view->pane && !view->external) {
          views.append(
              QJsonObject{{"id", id},
                          {"configuration", QJsonObject::fromVariantMap(view->configuration)}});
        }
      }

      state.insert("views", views);
      const auto key = tabKey(workspace_id, tab_id);
      if (persisted.value(key).toObject() != state) {
        persisted.insert(key, state);
        save_timer.start();
      }
    }

    void save() {
      TELAR_TRACE("workbench.save");
      for (const auto &[id, workspace] : workspaces) {
        for (const auto &[tab_id, tab] : workspace.tabs) {
          remember(id, tab_id, tab);
        }
      }

      QDir().mkpath(QFileInfo(persistence_path).absolutePath());
      QSaveFile file(persistence_path);
      if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "Cannot save workbench layout:" << file.errorString();
        return;
      }

      file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
      const auto bytes = QJsonDocument(persisted).toJson(QJsonDocument::Compact);
      if (bytes.size() > persistence_limit || file.write(bytes) != bytes.size() || !file.commit()) {
        qWarning() << "Cannot save workbench layout:" << file.errorString();
      }
    }

    View &
    addView(Tab &tab, Element element, QVariantMap configuration = {}, std::uint64_t pane = 0) {
      TELAR_TRACE("workbench.add_view");
      if (tab.views.size() >= Layout::capacity) {
        throw std::runtime_error("Tab surface limit reached");
      }

      auto view = std::make_unique<View>();
      view->pane = pane;
      view->title = element.title;
      view->configuration = std::move(configuration);
      const auto id = element.id;
      tab.layout.insert(std::move(element), tab.next_axis);
      auto &result = *view;
      tab.views.emplace(id, std::move(view));
      return result;
    }

    void materialize(Workspace &workspace, const QString &id, View &view) {
      TELAR_TRACE("workbench.create_surface");
      qCInfo(telar_log::workbench) << "create surface" << id << "pane" << view.pane;
      view.surface = std::make_unique<LuaSurface>(desktop,
                                                  QSize(320, 240),
                                                  ui::SurfaceKind::workbench,
                                                  view.configuration);
      auto &window = view.surface->window();
      // Qt's default persistence keeps a hidden window's scene graph, so showing it again draws
      // at once instead of rebuilding every terminal row before its first frame.
      window.setFlags(Qt::Window | Qt::FramelessWindowHint);
      window.setTitle(view.title.isEmpty() ? QStringLiteral("Telar Pane") : view.title);
      // The pane never becomes the key window: a press on it, or Lua focusing one of its items,
      // moves the tab's focus to it, and focusCurrent routes the keyboard there.
      keyboard.adopt(window, [this, id] {
        requestFocus(id);
      });

      view.surface->setFocusHandler([this, id] {
        requestFocus(id);
      });

      if (const auto pane = view.pane) {
        view.terminal =
            std::make_unique<TerminalItem>(workspace.runtime->screen(pane), window.contentItem());
        view.terminal->setZ(1);
        view.terminal->send = [&runtime = *workspace.runtime, pane](const QByteArray &bytes) {
          runtime.input(pane, bytes);
        };

        bindClipboardPaste(*view.terminal, *workspace.runtime, pane);

        view.terminal->desktopChanged = [&runtime = *workspace.runtime, pane](telar::ConfigurePaneDesktop state) {
          runtime.desktop(pane, state);
        };

        view.terminal->resized = [&runtime = *workspace.runtime, pane](telar::TerminalSize size) {
          runtime.resize(pane, size);
        };

        view.terminal->scrolled = [&runtime = *workspace.runtime, pane](std::uint32_t offset) {
          runtime.viewport(pane, offset);
        };

        // The terminal is the focus of its window, so it has active focus while the window holds
        // the keyboard.
        view.terminal->setFocus(true);
        view.terminal->configure(options);
      }
    }

    void synchronize(Workspace &workspace, std::uint64_t workspace_id) {
      TELAR_TRACE("workbench.synchronize");
      const auto &snapshots = workspace.runtime->tabs();
      for (const auto &[tab_id, panes] : snapshots) {
        auto &tab = workspace.tabs[tab_id];
        tab.id = tab_id;
        // Empty here can mean its first snapshot has not arrived yet. Every other tab is
        // synchronized too, so their windows can be prewarmed before they are visited.
        if (!workspace.runtime->hasSnapshot(tab_id)) {
          continue;
        }

        std::set<QString> live;
        for (const auto pane : panes) {
          const auto id = paneId(pane);
          live.insert(id);
          if (!tab.views.contains(id)) {
            Element element{id,
                            ContentKind::terminal,
                            QStringLiteral("Pane ") + QString::number(pane)};
            element.constraints.minimum = {160, 90};
            addView(tab, element, {}, pane);
            if (tab.focus_new) {
              tab.layout.focus(id);
              focus_pending = true;
              focus_workspace = workspace_id;
              tab.focus_new = false;
            }
          }
        }

        const auto previous_focus = tab.layout.focused();
        std::erase_if(tab.views, [&](const auto &entry) {
          if (entry.second->pane && !live.contains(entry.first)) {
            tab.layout.remove(entry.first);
            return true;
          }

          return false;
        });

        if (tab.layout.focused() != previous_focus && workspace.visible &&
            workspace.space == services.desktop.state().focused_space) {
          focus_pending = true;
          focus_workspace = workspace_id;
        }

        if (!tab.restored && !panes.empty()) {
          tab.restored = true;
          const auto saved = persisted.value(tabKey(workspace_id, tab_id)).toObject();
          for (const auto &entry : saved.value("views").toArray()) {
            if (tab.views.size() >= Layout::capacity) {
              break;
            }

            const auto record = entry.toObject();
            const auto id = record.value("id").toString();
            if (!id.startsWith("view:") || tab.views.contains(id)) {
              continue;
            }

            try {
              addView(tab,
                      Element{id, ContentKind::view, "Telar View"},
                      record.value("configuration").toObject().toVariantMap());
            } catch (const std::exception &failure) {
              qWarning() << "Cannot restore Telar view:" << failure.what();
            }
          }

          tab.layout.restore(saved);
        }
      }

      std::erase_if(workspace.tabs, [&](const auto &entry) {
        if (!snapshots.contains(entry.first) && workspace.runtime->ready()) {
          persisted.remove(tabKey(workspace_id, entry.first));
          // Its external windows, parked if the tab was hidden, join the tab shown instead.
          if (std::ranges::any_of(entry.second.views, [](const auto &view) {
                return view.second->external != 0;
              })) {
            schedule();
          }

          return true;
        }

        return false;
      });
    }

    // Every few seconds, what the windows cost: hidden windows keep their scene graph.
    void traceResources() {
#if TELAR_DEBUG
      if (++monitor_ticks % resource_trace_ticks != 0) {
        return;
      }

      std::size_t shown = 0, hidden = 0;
      for (const auto &[workspace_id, workspace] : workspaces) {
        for (const auto &[tab_id, tab] : workspace.tabs) {
          for (const auto &[id, view] : tab.views) {
            ++(view->visible ? shown : hidden);
          }
        }
      }

      qCInfo(telar_log::workbench)
          << "resources: resident" << session_log::residentBytes() / mebibyte << "MiB; windows"
          << shown << "shown" << hidden << "hidden";
#endif
    }

    View *findView(const QString &id) {
      for (auto &[workspace_id, workspace] : workspaces) {
        for (auto &[tab_id, tab] : workspace.tabs) {
          if (const auto found = tab.views.find(id); found != tab.views.end()) {
            return found->second.get();
          }
        }
      }

      return nullptr;
    }

    void arrived(const QString &id) {
      TELAR_TRACE("workbench.arrived");
      if (auto *view = findView(id)) {
        QObject::disconnect(view->first_frame);
      }

      if (incoming.erase(id)) {
        qCDebug(telar_log::workbench) << "first frame from" << id;
      }

      std::erase_if(incoming, [this](const auto &pending) {
        return !findView(pending);
      });

      if (incoming.empty()) {
        retire();
      }
    }

    void retire() {
      TELAR_TRACE("workbench.retire");
      retire_timer.stop();
      for (const auto &id : std::exchange(retiring, {})) {
        if (auto *view = findView(id)) {
          qCDebug(telar_log::workbench) << "hide outgoing" << id;
          try {
            hide(*view);
          } catch (const std::exception &failure) {
            view->error = QString::fromUtf8(failure.what());
          }
        }
      }
    }

    // A hidden workspace keeps its windows on its own Space, which macOS already keeps out of
    // sight, so returning to it shows their last frame instead of transparent windows.
    bool keepsSpace(const Workspace &workspace, std::uint64_t workspace_id) const {
      return std::ranges::any_of(services.desktop.state().spaces, [&](const auto &space) {
        return space.id == workspace.space && space.workspace == workspace_id && !space.fullscreen;
      });
    }

    // A pane window that has been shown is never hidden again: hiding asks the window server
    // whether it is on screen, makes Qt list every window, and waits for its render thread, which
    // together take several frames. It turns transparent instead, which also lets the mouse
    // through, and its surface reports itself hidden, so Lua treats it as gone and pauses its
    // animations. With its terminal detached, it has nothing left to draw.
    void hide(View &view) {
      TELAR_TRACE("workbench.hide");
      if (!view.visible) {
        return;
      }

      if (view.surface) {
        native::setVisible(view.surface->window(), false);
        auto state = view.surface->nativeState();
        state.insert("visible", false);
        view.surface->setNativeState(state);
      }

      if (view.external && !view.parked) {
        if (const auto *window = foreignWindow(view.external)) {
          windows->hide(view.external, window->space);
          view.parked = true;
        }
      }

      view.visible = false;
    }

    const native::ForeignWindow *foreignWindow(std::uint32_t id) const {
      const auto found = std::ranges::find(foreign.windows, id, &native::ForeignWindow::id);
      return found == foreign.windows.end() ? nullptr : &*found;
    }

    // tile, float, ignore or backstage, from the workbench's `windows` option, keyed by
    // application. Without a rule a window tiles, unless it is a dialog or cannot be resized.
    QString ruleFor(const native::ForeignWindow &window) const {
      const auto rule = options.value("windows").toMap().value(window.application).toString();
      if (adopted.contains(window.id) ||
          (rule != "float" && rule != "ignore" && rule != "tile" && rule != "backstage")) {
        return window.floating ? "float" : "tile";
      }

      return rule;
    }

    // Logs once per reason why a window the observer reports stays out of the layout.
    void skipped(const native::ForeignWindow &window, const char *reason) {
      auto &logged = unadopted[window.id];
      if (logged == reason) {
        return;
      }

      logged = reason;
      qCInfo(telar_log::workbench) << "not adopting window" << window.id << window.application
                                   << "on space" << window.space << "because" << reason;
    }

    // Every managed window belongs to one tab. A window seen for the first time joins the tab
    // shown on its workspace's Space; one that is gone, or now on another Space, leaves its tab
    // and joins the one shown there. Activating a window whose tab is not shown, with Cmd+Tab or
    // the Dock, shows its tab.
    void adoptWindows() {
      TELAR_TRACE("workbench.adopt_windows");
      std::map<std::uint32_t, std::pair<Workspace *, std::uint64_t>> homes;
      for (auto &[workspace_id, workspace] : workspaces) {
        for (auto &[tab_id, tab] : workspace.tabs) {
          for (auto it = tab.views.begin(); it != tab.views.end();) {
            const auto id = it->second->external;
            const auto *window = id ? foreignWindow(id) : nullptr;
            if (id && (!window || window->space != workspace.space)) {
              tab.layout.remove(it->first);
              it = tab.views.erase(it);
              focus_pending = true;
              continue;
            }

            // A size its application refused becomes the element's minimum, so the layout
            // makes room for it instead of letting it cover its neighbours.
            if (window && !window->minimum.isNull()) {
              auto &limits = tab.layout.element(it->first)->constraints;
              limits.minimum = limits.minimum.expandedTo(window->minimum).boundedTo(limits.maximum);
            }

            if (id) {
              homes[id] = {&workspace, tab_id};
            }

            ++it;
          }
        }
      }

      updateBackstage();
      std::erase_if(unadopted, [&](const auto &entry) {
        return !foreignWindow(entry.first);
      });

      for (const auto &window : foreign.windows) {
        const auto rule = ruleFor(window);
        const auto home = std::ranges::find_if(workspaces, [&](const auto &entry) {
          return entry.second.space && entry.second.space == window.space;
        });

        if (homes.contains(window.id) || window.backstage || rule == "ignore") {
          continue;
        }

        if (home == workspaces.end()) {
          skipped(window, "its Space holds no visible workspace");
          continue;
        }

        // A window its application opens while it takes over the display stays in front of it,
        // and joins the backstage once the takeover ends.
        if (rule == "backstage") {
          const auto takeover = takeovers.find(home->second.display);
          const auto *taking = takeover == takeovers.end() ? nullptr
                                                           : foreignWindow(takeover->second.window);
          // The observer reads the window's new layer on its next pass; until then the
          // backstage already lists it.
          if ((!taking || taking->pid != window.pid) &&
              !std::ranges::contains(backstage, window.id)) {
            sendToBackstage(window.id);
          }

          continue;
        }

        auto &workspace = home->second;
        const auto tab = workspace.tabs.find(workspace.runtime->activeTab());
        if (tab == workspace.tabs.end() || tab->second.views.size() >= Layout::capacity) {
          skipped(window, "its workspace has no tab with room");
          continue;
        }

        const auto id = "window:" + QString::number(window.id);
        Element element{id, ContentKind::external, window.title};
        if (rule == "float" && workspace.area.isValid()) {
          element.floating = true;
          element.floating_frame = relative(window.frame, workspace.area);
        }

        // Windows arriving together fill the tab as a grid, each halving the largest element.
        auto &layout = tab->second.layout;
        const auto gap = metric(options, "gap", default_gap);
        const bool inserted = element.floating
                                  ? layout.insert(element, tab->second.next_axis)
                                  : layout.insertBesideLargest(element, workspace.area, gap);
        if (!inserted) {
          skipped(window, "the layout refused it");
          continue;
        }

        auto view = std::make_unique<View>();
        view->external = window.id;
        view->title = window.title;
        view->actual = window.frame;
        tab->second.views.emplace(id, std::move(view));
        homes[window.id] = {&workspace, tab->first};
        unadopted.erase(window.id);
        qCInfo(telar_log::workbench) << "adopted" << id << window.application << "into tab"
                                     << tab->first << (element.floating ? "floating" : "tiled");
      }

      if (foreign.focused == followed_focus) {
        return;
      }

      // Cmd+Tab or the Dock reaching a backstage window brings it over the focused display.
      if (std::ranges::contains(backstage, foreign.focused) && !takingOver(foreign.focused)) {
        followed_focus = foreign.focused;
        try {
          takeOver(foreign.focused);
        } catch (const std::exception &failure) {
          qCWarning(telar_log::workbench) << "cannot take over for the focused window:"
                                          << failure.what();
        }

        return;
      }

      const auto home = homes.find(foreign.focused);
      if (home == homes.end()) {
        followed_focus = foreign.focused;
        return;
      }
      if (!home->second.first->visible) {
        return;
      }

      followed_focus = foreign.focused;
      if (home->second.first->runtime->activeTab() == home->second.second) {
        requestFocus("window:" + QString::number(foreign.focused));
        return;
      }

      try {
        services.runtime.selectTab(home->second.second);
      } catch (const std::exception &failure) {
        qCWarning(telar_log::workbench)
            << "cannot show the focused window's tab:" << failure.what();
      }
    }

    // The backstage keeps the windows the observer still lists, and takes back any found in it
    // that it lost track of, as when their application was hidden for a while. A takeover whose
    // window is gone ends.
    void updateBackstage() {
      std::erase_if(backstage, [&](const auto id) {
        return !foreignWindow(id);
      });

      for (const auto &window : foreign.windows) {
        if (window.backstage && !std::ranges::contains(backstage, window.id)) {
          backstage.push_back(window.id);
        }
      }

      for (const auto &[display, takeover] : std::map(takeovers)) {
        if (!foreignWindow(takeover.window)) {
          endTakeover(display);
        }
      }

      if (switcher && backstage.empty()) {
        switcher.reset();
      } else if (switcher) {
        switcher->selected = std::min(switcher->selected, backstage.size() - 1);
      }
    }

    // Opens the switcher on the focused display, on the most recent window not already taking
    // it over, or moves its selection by `step`.
    bool cycleBackstage(int step) {
      if (backstage.empty()) {
        return false;
      }

      const auto count = static_cast<std::ptrdiff_t>(backstage.size());
      if (switcher) {
        const auto next = (static_cast<std::ptrdiff_t>(switcher->selected) + step) % count;
        switcher->selected = static_cast<std::size_t>(next < 0 ? next + count : next);
        schedule();
        return true;
      }

      const auto *workspace = focusedWorkspace();
      if (!workspace || !workspace->visible) {
        throw std::runtime_error("No visible workspace is focused");
      }

      const auto taking = takeovers.find(workspace->display);
      const bool skip_first = taking != takeovers.end() && taking->second.window == backstage[0];
      std::size_t selected = skip_first && count > 1 ? 1 : 0;
      if (step < 0) {
        selected = static_cast<std::size_t>(count - 1);
      }

      switcher = Switcher{workspace->display, selected};
      schedule();
      return true;
    }

    bool takingOver(std::uint32_t window) const {
      return std::ranges::any_of(takeovers, [&](const auto &entry) {
        return entry.second.window == window;
      });
    }

    // Most recently used first.
    void touchBackstage(std::uint32_t window) {
      std::erase(backstage, window);
      backstage.insert(backstage.begin(), window);
    }

    void sendToBackstage(std::uint32_t window) {
      TELAR_TRACE("workbench.send_to_backstage");
      windows->sendToBackstage(window);
      std::erase_if(takeovers, [&](const auto &entry) {
        return entry.second.window == window;
      });

      for (auto &[workspace_id, workspace] : workspaces) {
        for (auto &[tab_id, tab] : workspace.tabs) {
          const auto id = "window:" + QString::number(window);
          if (tab.views.erase(id)) {
            tab.layout.remove(id);
            focus_pending = true;
          }
        }
      }

      touchBackstage(window);
      qCInfo(telar_log::workbench) << "window" << window << "sent to the backstage";
      schedule();
    }

    // Over the workspace the focused display shows.
    void takeOver(std::uint32_t window) {
      TELAR_TRACE("workbench.take_over");
      if (!std::ranges::contains(backstage, window)) {
        throw std::runtime_error("The window is not in the backstage");
      }

      auto *workspace = focusedWorkspace();
      if (!workspace || !workspace->visible || !workspace->area.isValid()) {
        throw std::runtime_error("No visible workspace is focused");
      }

      windows->takeOver(window, workspace->display, workspace->area);
      std::erase_if(takeovers, [&](const auto &entry) {
        return entry.second.window == window;
      });

      takeovers[workspace->display] = {window, workspace->space, workspace->runtime->activeTab()};
      followed_focus = window;
      touchBackstage(window);
      qCInfo(telar_log::workbench) << "window" << window << "takes over display"
                                   << workspace->display;
      schedule();
    }

    // The display's layout comes back, with the keyboard.
    void endTakeover(std::uint32_t display) {
      TELAR_TRACE("workbench.end_takeover");
      const auto found = takeovers.find(display);
      if (found == takeovers.end()) {
        return;
      }

      const auto space = found->second.space;
      takeovers.erase(found);
      windows->endTakeover(display);
      for (const auto &[id, workspace] : workspaces) {
        if (workspace.space == space) {
          focus_pending = true;
          focus_workspace = id;
        }
      }

      schedule();
    }

    // Going anywhere else in a display's layout ends its takeover: another Space or another tab.
    void followTakeovers() {
      for (const auto &[display, takeover] : std::map(takeovers)) {
        const auto workspace = std::ranges::find_if(workspaces, [&](const auto &entry) {
          return entry.second.space == takeover.space;
        });

        if (workspace == workspaces.end() || !workspace->second.visible ||
            workspace->second.runtime->activeTab() != takeover.tab) {
          endTakeover(display);
        }
      }
    }

    static QRectF relative(const QRectF &frame, const QRectF &area) {
      return {(frame.x() - area.x()) / area.width(),
              (frame.y() - area.y()) / area.height(),
              frame.width() / area.width(),
              frame.height() / area.height()};
    }

    // Puts a pane window where the layout places it, on its workspace's Space, and tells its
    // surface where it is and whether the user sees it. Showing the window is up to the caller.
    void
    layOut(Workspace &workspace, Tab &tab, const Placement &placement, View &view, bool shown) {
      TELAR_TRACE("workbench.lay_out");
      const auto padding = metric(options, "padding", default_padding);
      const auto header = metric(options, "header_height", default_header);
      auto &window = view.surface->window();
      const QRect geometry(QPoint(qRound(placement.frame.left()), qRound(placement.frame.top())),
                           QSize(qRound(placement.frame.right()) - qRound(placement.frame.left()),
                                 qRound(placement.frame.bottom()) - qRound(placement.frame.top())));
      if (native::frame(window) != geometry) {
        native::setFrame(window, geometry);
      }

      if (view.placed_space != workspace.space) {
        native::place(window, workspace.space);
        view.placed_space = workspace.space;
      }

      const QRectF content(padding,
                           header,
                           std::max(0.0, placement.frame.width() - padding * 2),
                           std::max(0.0, placement.frame.height() - header - padding));
      view.surface->setNativeState(
          {{"element", placement.id},
           {"pane", view.pane ? QVariant(QString::number(view.pane)) : QVariant{}},
           {"workspace", QString::number(workspace.id)},
           {"tab", QString::number(tab.id)},
           {"focused", tab.layout.focused() == placement.id},
           {"floating", tab.layout.element(placement.id)->floating},
           {"visible", shown},
           {"area", rectangle(workspace.area)},
           {"geometry", rectangle(placement.frame)},
           {"content", rectangle(content)}});
      if (view.terminal) {
        view.terminal->setPosition(content.topLeft());
        view.terminal->setSize(content.size());
      }
    }

    void present(Workspace &workspace, std::uint64_t workspace_id, bool reconfigure) {
      TELAR_TRACE("workbench.present");
      const auto gap = metric(options, "gap", default_gap);
      const auto active_tab = workspace.runtime->activeTab();
      std::set<QString> shown;
      for (auto &[tab_id, tab] : workspace.tabs) {
        // Lua can close its own surface. Retire it after the callback has returned.
        for (const auto &id : tab.closing) {
          tab.layout.remove(id);
          tab.views.erase(id);
        }
        tab.closing.clear();
        const bool visible = workspace.visible && tab_id == active_tab;
        const auto placements = visible ? tab.layout.arrange(workspace.area, gap, workspace.scale)
                                        : std::vector<Placement>{};
        for (const auto &placement : placements) {
          auto found = tab.views.find(placement.id);
          if (found == tab.views.end()) {
            continue;
          }

          auto &view = *found->second;
          shown.insert(placement.id);
          view.requested = placement.frame;
          try {
            if (view.external) {
              const auto *window = foreignWindow(view.external);
              if (!window) {
                continue;
              }

              // A floating window the user moved stays where they left it.
              const auto *element = tab.layout.element(placement.id);
              if (element->floating && !view.parked && view.visible &&
                  window->frame != view.applied && workspace.area.isValid()) {
                tab.layout.setFloatingFrame(placement.id, relative(window->frame, workspace.area));
                view.applied = window->frame;
              } else if (view.parked || !view.visible || view.applied != placement.frame) {
                windows->place(view.external, workspace.space, placement.frame);
                view.applied = placement.frame;
                view.parked = false;
              }

              view.actual = window->frame;
              if (!focus_pending && workspace.space == services.desktop.state().focused_space &&
                  foreign.focused == view.external && tab.layout.focused() != placement.id) {
                tab.layout.focus(placement.id);
              }
            } else {
              if (!view.surface) {
                materialize(workspace, placement.id, view);
              }

              auto &window = view.surface->window();
              layOut(workspace, tab, placement, view, true);
              if (view.terminal) {
                if (reconfigure) {
                  view.terminal->configure(options);
                }

                view.terminal->setPresented(true);
              }

              // A retired window still holds its last frame, so only a window shown for the
              // first time has to draw before the outgoing ones go.
              const bool first = !window.isVisible();
              if (!view.visible) {
                qCDebug(telar_log::workbench)
                    << "show" << placement.id << "at" << placement.frame << "in tab" << tab_id;
                native::setVisible(window, true);
              }

              {
                TELAR_TRACE("workbench.window.show");
                window.show();
              }

              retiring.erase(placement.id);
              if (first) {
                incoming.insert(placement.id);
                QObject::disconnect(view.first_frame);
                view.first_frame = QObject::connect(
                    &window,
                    &QQuickWindow::frameSwapped,
                    &owner,
                    [this, id = placement.id] {
                      arrived(id);
                    },
                    Qt::QueuedConnection);
              }

              if (view.shown_order != placement.order) {
                native::raise(window);
                view.shown_order = placement.order;
              }

              view.actual = native::frame(window);
            }

            view.visible = true;
            view.error.clear();
          } catch (const std::exception &failure) {
            view.error = QString::fromUtf8(failure.what());
            qCWarning(telar_log::workbench)
                << "cannot present" << placement.id << ":" << view.error;
            if (view.surface) {
              view.surface->window().hide();
            }

            view.visible = false;
          }
        }
      }

      const bool keep = !workspace.visible && keepsSpace(workspace, workspace_id);
      for (auto &[tab_id, tab] : workspace.tabs) {
        for (auto &[id, view] : tab.views) {
          if (shown.contains(id)) {
            continue;
          }

          if (view->terminal) {
            view->terminal->setPresented(false);
          }

          if (keep || !view->visible) {
            continue;
          }

          if (!incoming.empty()) {
            qCDebug(telar_log::workbench) << "keep" << id << "until the incoming windows draw";
            retiring.insert(id);
            if (!retire_timer.isActive()) {
              retire_timer.start();
            }

            continue;
          }

          qCDebug(telar_log::workbench) << "hide" << id << "of tab" << tab_id;
          try {
            hide(*view);
          } catch (const std::exception &failure) {
            view->error = QString::fromUtf8(failure.what());
          }
        }
      }
    }

    // Prepares the panes the user is not looking at, one phase of one pane per call, so the first
    // visit to any tab, in any workspace, finds windows that exist, sit on their Space and have
    // drawn, as when returning to a tab. A phase is making the surface, making the native window
    // and placing it, or showing it transparent so it draws; each fits in a frame. Visible
    // workspaces go first. Returns whether anything is left.
    bool prewarm() {
      TELAR_TRACE("workbench.prewarm");
      const auto gap = metric(options, "gap", default_gap);
      for (const bool visible : {true, false}) {
        for (auto &[workspace_id, workspace] : workspaces) {
          if (workspace.visible != visible || !workspace.space) {
            continue;
          }

          for (auto &[tab_id, tab] : workspace.tabs) {
            for (auto &[id, view] : tab.views) {
              if (view->external || view->visible || view->retired()) {
                continue;
              }

              if (!view->surface) {
                materialize(workspace, id, *view);
                return true;
              }

              if (view->placed_space != workspace.space) {
                for (const auto &placement :
                     tab.layout.arrange(workspace.area, gap, workspace.scale)) {
                  if (placement.id == id) {
                    layOut(workspace, tab, placement, *view, false);
                    return true;
                  }
                }

                continue;
              }

              auto &window = view->surface->window();
              native::setVisible(window, false);
              window.show();
              return true;
            }
          }
        }
      }

      return false;
    }

    void reconcile() {
      TELAR_TRACE("workbench.reconcile");
      if (changing) {
        schedule();
        return;
      }

      changing = true;
      std::map<std::uint64_t, bool> was_visible;
      for (const auto &[id, workspace] : workspaces) {
        was_visible[id] = workspace.visible;
      }

      try {
        auto configured = desktop.options(ui::SurfaceKind::workbench);
        configured.insert(QStringLiteral("theme"), desktop.theme());
        const bool reconfigure = configured != options;
        options = configured;
        for (auto &[id, workspace] : workspaces) {
          workspace.visible = false;
        }

        const auto &catalog = services.runtime.state();
        if (focused_space != services.desktop.state().focused_space) {
          focused_space = services.desktop.state().focused_space;
          focus_pending = true;
          focus_workspace = services.desktop.focusedWorkspace().value_or(0);
        }

        // Hidden workspaces too: their tabs are loaded and their windows prewarmed on their own
        // Space, so switching to one is as cheap as switching tabs.
        for (const auto &space : services.desktop.state().spaces) {
          if (!space.workspace || space.fullscreen) {
            continue;
          }

          const auto id = *space.workspace;
          auto &workspace = workspaces[id];
          workspace.id = id;
          if (!workspace.runtime) {
            workspace.runtime = std::make_unique<RuntimeConnection>(
                QString::fromStdString(services.runtime_socket),
                telar::WorkspaceLocation{telar::WorkspaceLocation::Kind::workspace, id});

            workspace.runtime->changed = [this] {
              schedule();
            };

            workspace.runtime->created = [this, &workspace](std::uint64_t tab) {
              workspace.created_tab = tab;
              schedule();
            };

            workspace.runtime->painted = [&workspace](std::uint64_t pane) {
              for (auto &[tab_id, tab] : workspace.tabs) {
                const auto found = tab.views.find(paneId(pane));

                if (found != tab.views.end() && found->second->terminal) {
                  found->second->terminal->refresh();
                }
              }
            };
          }

          workspace.space = space.id;
          workspace.display = space.display;
          const auto monitor = native::display(space.display);
          const auto margin = metric(options, "margin", default_gap);

          workspace.area = desktop.workArea(space.display, monitor.available)
                               .adjusted(margin, margin, -margin, -margin);

          workspace.scale = monitor.scale;
          if (!space.visible) {
            workspace.runtime->load();
            continue;
          }

          workspace.visible = true;
          const auto *view = catalog.view(RuntimeWorkspace{id});
          if (view && workspace.created_tab &&
              std::ranges::find(view->tabs, workspace.created_tab, &RuntimeTab::id) !=
                  view->tabs.end()) {
            services.runtime.selectTab(std::exchange(workspace.created_tab, 0));
          }

          if (view && view->active_tab) {
            if (workspace.runtime->activeTab() != view->active_tab && space.focused) {
              focus_pending = true;
            }

            workspace.runtime->selectTab(view->active_tab);
          }
        }

        followTakeovers();
        adoptWindows();

        // Incoming workspaces go first, so their windows are up before the outgoing ones hide.
        for (const bool visible : {true, false}) {
          for (auto &[id, workspace] : workspaces) {
            if (workspace.visible != visible) {
              continue;
            }

            if (was_visible[id] != workspace.visible) {
              qCInfo(telar_log::workbench)
                  << "workspace" << id << (workspace.visible ? "visible" : "hidden") << "on space"
                  << workspace.space << "tab" << workspace.runtime->activeTab();
            }

            workspace.runtime->setVisible(workspace.visible);
            synchronize(workspace, id);
            present(workspace, id, reconfigure);

            for (const auto &[tab_id, tab] : workspace.tabs) {
              remember(id, tab_id, tab);
            }
          }
        }

        if (catalog.workspaces_ready) {
          for (auto entry = persisted.begin(); entry != persisted.end();) {
            bool valid = false;
            const auto workspace_id = entry.key().section('/', 0, 0).toULongLong(&valid);
            const bool live = valid && std::any_of(catalog.workspaces.begin(),
                                                   catalog.workspaces.end(),
                                                   [&](const auto &workspace) {
                                                     return workspace.id == workspace_id;
                                                   });
            if (!live) {
              entry = persisted.erase(entry);
              save_timer.start();
            } else {
              ++entry;
            }
          }

          std::erase_if(workspaces, [&](const auto &entry) {
            return std::none_of(catalog.workspaces.begin(),
                                catalog.workspaces.end(),
                                [&](const auto &workspace) {
                                  return workspace.id == entry.first;
                                });
          });
        }

        // A tab showing other applications' windows outlives its last terminal.
        std::set<std::pair<RuntimeWorkspace, std::uint64_t>> holds;
        for (const auto &[workspace_id, workspace] : workspaces) {
          for (const auto &[tab_id, tab] : workspace.tabs) {
            if (std::ranges::any_of(tab.views, [](const auto &view) {
                  return view.second->external != 0;
                })) {
              holds.insert({RuntimeWorkspace{workspace_id}, tab_id});
            }
          }
        }

        services.runtime.holdTabs(std::move(holds));

        if (focus_pending && focusCurrent()) {
          focus_pending = false;
          focus_workspace = 0;
        }

        outlineFocus();
        acknowledgeFocusedAgent();

        error.clear();
      } catch (const std::exception &failure) {
        error = QString::fromUtf8(failure.what());
        qCWarning(telar_log::workbench) << "reconciliation failed:" << error;
      }

      changing = false;
      prewarming.wake();
      const auto current = state();
      if (notified_state != current) {
        notified_state = current;
        notify();
      }
    }

    // A done agent stays done until the client showing its pane focused acknowledges it, once
    // per turn, as the GUI does; the runtime then reports it ready.
    void acknowledgeFocusedAgent() {
      TELAR_TRACE("workbench.acknowledge_focused_agent");
      const auto agents = services.runtime.state().agents;
      if (!agents) {
        return;
      }

      const auto done = [&](std::uint64_t pane, std::uint64_t generation) {
        return std::ranges::find_if(*agents, [&](const RuntimeAgent &agent) {
          return agent.pane == pane && (!generation || agent.generation == generation) &&
                 agent.status == "done";
        });
      };

      if (acknowledged && done(acknowledged->first, acknowledged->second) == agents->end()) {
        acknowledged.reset();
      }

      auto *workspace = focusedWorkspace();
      if (!workspace || !workspace->visible) {
        return;
      }

      const auto tab = workspace->tabs.find(workspace->runtime->activeTab());
      if (tab == workspace->tabs.end()) {
        return;
      }

      const auto view = tab->second.views.find(tab->second.layout.focused());
      if (view == tab->second.views.end() || !view->second->pane) {
        return;
      }

      const auto agent = done(view->second->pane, 0);
      if (agent == agents->end()) {
        return;
      }

      const std::pair key{agent->pane, agent->generation};
      if (acknowledged == key) {
        return;
      }

      acknowledged = key;
      qCDebug(telar_log::workbench) << "acknowledge done agent of pane" << key.first;
      try {
        services.runtime.acknowledgeAgent(key.first, key.second);
      } catch (const std::exception &failure) {
        acknowledged.reset();
        qCWarning(telar_log::workbench) << "cannot acknowledge the agent:" << failure.what();
      }
    }

    bool focusCurrent() {
      TELAR_TRACE("workbench.focus_current");
      auto *workspace = focusedWorkspace();
      if (focus_workspace && workspaces.contains(focus_workspace)) {
        workspace = &workspaces.at(focus_workspace);
      }

      if (!workspace || !workspace->visible) {
        qCDebug(telar_log::workbench) << "focus waits: no visible workspace";
        return false;
      }

      const auto found = workspace->tabs.find(workspace->runtime->activeTab());
      if (found == workspace->tabs.end()) {
        qCDebug(telar_log::workbench) << "focus waits: tab" << workspace->runtime->activeTab()
                                      << "not loaded";
        return false;
      }

      auto &tab = found->second;
      const auto target = tab.views.find(tab.layout.focused());
      if (target == tab.views.end() || !target->second->visible) {
        qCDebug(telar_log::workbench) << "focus waits:" << tab.layout.focused() << "of tab"
                                      << tab.id << "not shown";
        return false;
      }

      qCDebug(telar_log::workbench) << "focus" << target->first << "of tab" << tab.id;
      auto &view = *target->second;
      if (view.external) {
        if (foreign.focused != view.external) {
          windows->focus(view.external);
        }
      } else {
        // Raising asks the window server to restack; only a floating pane can be covered.
        if (tab.layout.element(target->first)->floating) {
          native::raise(view.surface->window());
        }

        keyboard.route(view.surface->window());
      }

      return true;
    }

    // The focused element when it is another application's window shown on the focused display,
    // unless a backstage window has taken that display over.
    const native::ForeignWindow *focusedForeignWindow() {
      auto *workspace = focusedWorkspace();
      if (!workspace || !workspace->visible || takeovers.contains(workspace->display)) {
        return nullptr;
      }

      const auto tab = workspace->tabs.find(workspace->runtime->activeTab());
      if (tab == workspace->tabs.end()) {
        return nullptr;
      }

      const auto view = tab->second.views.find(tab->second.layout.focused());
      if (view == tab->second.views.end() || !view->second->external || !view->second->visible ||
          view->second->parked) {
        return nullptr;
      }

      return foreignWindow(view->second->external);
    }

    // Puts the ring around the window the observer last saw, its actual frame rather than the
    // one asked for, on the window's Space and right above it. Hiding it turns it transparent,
    // as a retired pane does.
    void outlineFocus() {
      TELAR_TRACE("workbench.outline_focus");
      const auto *target = focusedForeignWindow();
      if (!target) {
        if (focus_ring.shown) {
          native::setVisible(focus_ring.surface->window(), false);
          focus_ring.shown = false;
          focus_ring.target = 0;
        }

        return;
      }

      if (!focus_ring.surface) {
        const QVariantMap options{{"thickness", focus_ring_thickness}};
        focus_ring.surface = std::make_unique<LuaSurface>(
            desktop,
            QSize(1, 1),
            ui::SurfaceKind::workbench,
            QVariantMap{{"module", "focus_ring"}, {"options", options}});
        auto &window = focus_ring.surface->window();
        window.setFlags(Qt::Window | Qt::FramelessWindowHint | Qt::WindowDoesNotAcceptFocus |
                        Qt::WindowTransparentForInput);
        window.setTitle(QStringLiteral("Telar Focus Ring"));
      }

      auto &window = focus_ring.surface->window();
      const auto frame = target->frame.toAlignedRect().adjusted(-focus_ring_thickness,
                                                                -focus_ring_thickness,
                                                                focus_ring_thickness,
                                                                focus_ring_thickness);
      if (focus_ring.frame != frame) {
        native::setFrame(window, frame);
        focus_ring.frame = frame;
      }

      const auto space = focusedWorkspace()->space;
      if (focus_ring.space != space) {
        native::place(window, space);
        focus_ring.space = space;
      }

      if (focus_ring.shown && focus_ring.target == target->id) {
        return;
      }

      native::setVisible(window, true);
      window.show();
      native::orderAbove(window, target->id);
      focus_ring.shown = true;
      focus_ring.target = target->id;
    }

    void requestFocus(const QString &id) {
      TELAR_TRACE("workbench.request_focus");
      // Focus can be requested while tabs or windows are being removed.
      if (changing) {
        return;
      }

      for (auto &[workspace_id, workspace] : workspaces) {
        for (auto &[tab_id, tab] : workspace.tabs) {
          if (const auto found = tab.views.find(id);
              found != tab.views.end() && !found->second->retired()) {
            tab.layout.focus(id);
            focus_pending = true;
            focus_workspace = workspace_id;
            save_timer.start();
            schedule();
            return;
          }
        }
      }
    }

    QVariantMap state() const {
      TELAR_TRACE("workbench.state");
      QVariantList workspace_list;
      for (const auto &[id, workspace] : workspaces) {
        QVariantList tabs;
        for (const auto &[tab_id, tab] : workspace.tabs) {
          QVariantList elements;
          for (const auto &element : tab.layout.elements()) {
            const auto found = tab.views.find(element.id);
            if (found == tab.views.end()) {
              continue;
            }

            const auto &view = *found->second;
            elements.append(QVariantMap{{"id", element.id},
                                        {"kind",
                                         element.kind == ContentKind::terminal ? "terminal"
                                         : element.kind == ContentKind::view   ? "view"
                                                                               : "external"},
                                        {"title", element.title},
                                        {"visible", view.visible},
                                        {"floating", element.floating},
                                        {"requested", rectangle(view.requested)},
                                        {"actual", rectangle(view.actual)},
                                        {"error", view.error}});
          }

          tabs.append(QVariantMap{{"id", QString::number(tab_id)},
                                  {"focused", tab.layout.focused()},
                                  {"elements", elements}});
        }

        workspace_list.append(
            QVariantMap{{"id", QString::number(id)},
                        {"active_tab", QString::number(workspace.runtime->activeTab())},
                        {"area", rectangle(workspace.area)},
                        {"visible", workspace.visible},
                        {"connected", workspace.runtime->ready()},
                        {"error", workspace.runtime->error()},
                        {"tabs", tabs}});
      }

      QVariantList backstage_list;
      for (const auto id : backstage) {
        if (const auto *window = foreignWindow(id)) {
          backstage_list.append(QVariantMap{{"window", QString::number(id)},
                                            {"application", window->application},
                                            {"title", window->title},
                                            {"pid", QString::number(window->pid)},
                                            {"taking_over", takingOver(id)}});
        }
      }

      QVariant switcher_state;
      if (switcher && switcher->selected < backstage.size()) {
        switcher_state =
            QVariantMap{{"display", QString::number(switcher->display)},
                        {"window", QString::number(backstage[switcher->selected])}};
      }

      const auto current = services.desktop.focusedWorkspace();
      return {{"workspace", current ? QVariant(QString::number(*current)) : QVariant{}},
              {"workspaces", workspace_list},
              {"backstage", backstage_list},
              {"switcher", switcher_state},
              {"error", error}};
    }

    std::uint32_t windowArgument(const QVariantMap &args) const {
      const auto id = identifier(args.value("window"));
      if (id > std::numeric_limits<std::uint32_t>::max() ||
          !foreignWindow(static_cast<std::uint32_t>(id))) {
        throw std::runtime_error("No managed application has that window");
      }

      return static_cast<std::uint32_t>(id);
    }

    QVariant command(const QString &action, const QVariantMap &args) {
      TELAR_TRACE("workbench.command");
      qCInfo(telar_log::workbench) << "command" << action << args;
      if (action == "windows") {
        QVariantList list;
        for (const auto &window : foreign.windows) {
          list.append(QVariantMap{{"id", QString::number(window.id)},
                                  {"application", window.application},
                                  {"title", window.title},
                                  {"floating", window.floating}});
        }

        return list;
      }

      if (action == "take_over") {
        takeOver(windowArgument(args));
        return true;
      }

      if (action == "cycle_backstage") {
        return cycleBackstage(args.value("step", 1).toInt());
      }

      if (action == "take_over_selected") {
        const auto chosen = std::exchange(switcher, std::nullopt);
        schedule();
        if (!chosen || chosen->selected >= backstage.size()) {
          return false;
        }

        takeOver(backstage[chosen->selected]);
        return true;
      }

      if (action == "close_backstage") {
        switcher.reset();
        schedule();
        return true;
      }

      if (action == "end_takeover") {
        const auto *focused = focusedWorkspace();
        if (focused) {
          endTakeover(focused->display);
        }

        return true;
      }

      if (action == "send_to_backstage" && args.contains("window")) {
        sendToBackstage(windowArgument(args));
        return true;
      }

      auto *workspace = focusedWorkspace();
      if (args.contains("workspace")) {
        const auto found = workspaces.find(identifier(args.value("workspace")));
        workspace = found == workspaces.end() ? nullptr : &found->second;
      }

      if (!workspace) {
        throw std::runtime_error("No visible workspace is focused");
      }

      if (!workspace->visible ||
          (args.contains("tab") && action != "move" &&
           identifier(args.value("tab")) != workspace->runtime->activeTab())) {
        throw std::runtime_error("The command's tab is no longer visible");
      }

      auto found = workspace->tabs.find(workspace->runtime->activeTab());
      if (found == workspace->tabs.end()) {
        throw std::runtime_error("Workspace is waiting for its tab snapshot");
      }

      auto &tab = found->second;
      const auto id = args.value("id", tab.layout.focused()).toString();
      if (action == "send_to_backstage") {
        const auto view = tab.views.find(id);
        if (view == tab.views.end() || !view->second->external) {
          throw std::runtime_error("Only other applications' windows go to the backstage");
        }

        sendToBackstage(view->second->external);
        return true;
      }

      // Acting on the layout brings it back.
      endTakeover(workspace->display);
      QVariant result = true;
      if (action == "focus") {
        result = tab.layout.focus(id);
        focus_pending = true;
      } else if (action == "navigate") {
        result = tab.layout.navigate(direction(args.value("direction").toString()),
                                     workspace->area,
                                     metric(options, "gap", default_gap));
        focus_pending = true;
      } else if (action == "cycle") {
        result = tab.layout.cycle(args.value("step", 1).toInt());
        focus_pending = true;
      } else if (action == "swap") {
        result = tab.layout.swap(id, args.value("with").toString());
      } else if (action == "resize") {
        const double amount = args.value("amount", 0.05).toDouble();
        if (!std::isfinite(amount) || amount < 0 || amount > 1) {
          throw std::runtime_error("Resize amount must be a ratio between zero and one");
        }

        result = tab.layout.resize(direction(args.value("direction").toString()), amount);
      } else if (action == "maximize") {
        tab.layout.maximize();
        focus_pending = true;
      } else if (action == "float") {
        const auto *element = tab.layout.element(id);
        if (!element) {
          return false;
        }

        tab.layout.floatElement(id, args.value("enabled", !element->floating).toBool());
      } else if (action == "frame") {
        const auto rect = args.value("frame").toMap();
        tab.layout.setFloatingFrame(id,
                                    {rect.value("x").toDouble(),
                                     rect.value("y").toDouble(),
                                     rect.value("width").toDouble(),
                                     rect.value("height").toDouble()});
      } else if (action == "constraints") {
        auto *element = tab.layout.element(id);
        if (!element) {
          return false;
        }

        const auto minimum = args.value("minimum").toMap();
        const auto maximum = args.value("maximum").toMap();
        Constraints limits;
        limits.minimum = {
            minimum.value("width", element->constraints.minimum.width()).toDouble(),
            minimum.value("height", element->constraints.minimum.height()).toDouble()};
        limits.maximum = {
            maximum.value("width", element->constraints.maximum.width()).toDouble(),
            maximum.value("height", element->constraints.maximum.height()).toDouble()};
        limits.aspect = args.value("aspect", element->constraints.aspect).toDouble();
        const auto finite = [](QSizeF size) {
          return std::isfinite(size.width()) && std::isfinite(size.height());
        };

        if (!finite(limits.minimum) || !finite(limits.maximum) || limits.minimum.width() <= 0 ||
            limits.minimum.height() <= 0 || limits.maximum.width() < limits.minimum.width() ||
            limits.maximum.height() < limits.minimum.height() || !std::isfinite(limits.aspect) ||
            limits.aspect < 0) {
          throw std::runtime_error("Invalid element size constraints");
        }

        if (limits.aspect > 0) {
          limits.minimum = {
              std::max(limits.minimum.width(), limits.minimum.height() * limits.aspect),
              std::max(limits.minimum.height(), limits.minimum.width() / limits.aspect)};
          if (limits.minimum.width() > limits.maximum.width() ||
              limits.minimum.height() > limits.maximum.height()) {
            throw std::runtime_error("Aspect ratio cannot satisfy element size constraints");
          }
        }

        element->constraints = limits;
      } else if (action == "split") {
        if (!workspace->runtime->ready()) {
          throw std::runtime_error("Runtime is disconnected");
        }

        const auto axis = args.value("axis", "horizontal").toString();
        if (axis != "horizontal" && axis != "vertical") {
          throw std::runtime_error("Split axis must be horizontal or vertical");
        }

        const auto source = tab.views.find(id);
        workspace->runtime->split(source == tab.views.end() ? 0 : source->second->pane);
        tab.next_axis = axis == "vertical" ? Axis::vertical : Axis::horizontal;
        tab.focus_new = true;
      } else if (action == "new_tab") {
        const auto source = tab.views.find(id);
        workspace->runtime->createTab(source == tab.views.end() ? 0 : source->second->pane);
      } else if (action == "close") {
        const auto view = tab.views.find(id);
        if (view == tab.views.end()) {
          return false;
        }

        // The window leaves its tab once its application has closed it.
        if (view->second->pane) {
          workspace->runtime->close(view->second->pane);
        } else if (view->second->external) {
          windows->close(view->second->external);
        } else {
          tab.closing.insert(id);
        }

        focus_pending = true;
      } else if (action == "view") {
        const auto module = args.value("module").toString();
        if (module.isEmpty()) {
          throw std::runtime_error("A view requires a Lua module");
        }

        const auto view_id = "view:" + QUuid::createUuid().toString(QUuid::WithoutBraces);
        addView(tab,
                Element{view_id, ContentKind::view, args.value("title", "Telar View").toString()},
                {{"module", module}, {"options", args.value("options", QVariantMap{})}});
        tab.layout.focus(view_id);
        focus_pending = true;
        result = view_id;
      } else if (action == "adopt") {
        // A rule may ignore the window's application; adopting it overrides that, and it joins
        // the tab shown on its Space.
        const auto window_id = identifier(args.value("window"));
        if (window_id > std::numeric_limits<std::uint32_t>::max() ||
            !foreignWindow(static_cast<std::uint32_t>(window_id))) {
          throw std::runtime_error("No managed application has that window");
        }

        adopted.insert(static_cast<std::uint32_t>(window_id));
        schedule();
        result = "window:" + QString::number(window_id);
      } else if (action == "move") {
        const auto destination = identifier(args.value("tab"));
        if (!workspace->tabs.contains(destination)) {
          throw std::runtime_error("Destination tab is not known");
        }

        const auto view = tab.views.find(id);
        if (view == tab.views.end()) {
          return false;
        }

        if (view->second->pane) {
          throw std::runtime_error(
              "Moving terminal panes between tabs requires runtime protocol support");
        }

        auto &target = workspace->tabs.at(destination);
        if (destination == workspace->runtime->activeTab()) {
          return true;
        }

        auto element = *tab.layout.element(id);
        if (!target.layout.insert(element)) {
          return false;
        }

        hide(*view->second);
        target.views.emplace(id, std::move(view->second));
        tab.views.erase(view);
        tab.layout.remove(id);
      } else {
        throw std::runtime_error("Unknown workbench action");
      }

      save_timer.start();
      if (focus_pending) {
        for (const auto &[id, value] : workspaces) {
          if (&value == workspace) {
            focus_workspace = id;
            break;
          }
        }
      }

      schedule();
      return result;
    }
  };

  Controller::Controller(ui::DesktopUi &desktop)
      : impl_(std::make_unique<Impl>(*this, desktop)) {
    desktop.services().workbench = this;
  }

  Controller::~Controller() {
    impl_->services.workbench = nullptr;
  }

  QVariantMap Controller::state() const {
    return impl_->state();
  }

  std::optional<std::uint32_t> Controller::switcherDisplay() const {
    return impl_->switcher ? std::optional{impl_->switcher->display} : std::nullopt;
  }

  QVariant Controller::command(const QString &action, const QVariantMap &options) {
    return impl_->command(action, options);
  }

  std::uint64_t Controller::subscribe(std::function<void()> callback) {
    const auto id = impl_->next_subscription++;
    impl_->subscribers.emplace(id, std::move(callback));
    return id;
  }

  void Controller::unsubscribe(std::uint64_t identifier) {
    impl_->subscribers.erase(identifier);
  }
} // namespace workbench
