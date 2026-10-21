#include "controller.hpp"
#include "layout.hpp"
#include "native.hpp"
#include "runtime_connection.hpp"
#include "terminal_item.hpp"
#include "../desktop_ui.hpp"
#include "../lua_surface.hpp"
#include "../services.hpp"
#include "../../desktop_registry.hpp"
#include "../../desktop_session.hpp"
#include "../../runtime_session.hpp"
#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QScreen>
#include <QTimer>
#include <QUuid>
#include <algorithm>
#include <cmath>
#include <set>

namespace workbench {
  namespace {
    constexpr int geometry_interval_ms = 1000;
    constexpr int persistence_delay_ms = 300;
    constexpr int default_gap = 8, default_padding = 8, default_header = 28;
    constexpr int maximum_metric = 256;
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
    struct View {
      std::uint64_t pane = 0;
      std::unique_ptr<LuaSurface> surface;
      std::unique_ptr<TerminalItem> terminal;
      std::unique_ptr<native::ExternalWindow> external;
      QVariantMap configuration;
      QRectF requested, actual, applied;
      std::uint64_t placed_space = 0;
      int shown_order = 0;
      QString error;
      bool visible = false;
    };

    struct Tab {
      Layout layout;
      std::map<QString, std::unique_ptr<View>> views;
      std::set<QString> closing;
      bool restored = false;
      Axis next_axis = Axis::horizontal;
      bool focus_new = false;
    };

    struct Workspace {
      std::unique_ptr<RuntimeConnection> runtime;
      std::map<std::uint64_t, Tab> tabs;
      std::uint64_t space = 0;
      std::uint32_t display = 0;
      QRectF area;
      double scale = 1;
      bool visible = false;
    };

    Controller &owner;
    ui::DesktopUi &desktop;
    ui::Services &services;
    QTimer update_timer, monitor_timer, save_timer;
    std::uint64_t runtime_subscription = 0, desktop_subscription = 0;
    std::map<std::uint64_t, Workspace> workspaces;
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

      QObject::connect(&update_timer, &QTimer::timeout, &owner, [this] {
        reconcile();
      });

      QObject::connect(&monitor_timer, &QTimer::timeout, &owner, [this] {
        schedule();
      });

      QObject::connect(&save_timer, &QTimer::timeout, &owner, [this] {
        save();
      });

      runtime_subscription = services.runtime.subscribe([this] {
        schedule();
      });

      desktop_subscription = services.desktop.subscribe([this] {
        schedule();
      });

      desktop.changed = [this] {
        schedule();
      };

      monitor_timer.start();
      schedule();
    }

    ~Impl() {
      services.runtime.unsubscribe(runtime_subscription);
      services.desktop.unsubscribe(desktop_subscription);
      desktop.changed = {};
      save();
      // Surfaces and their Lua callbacks disappear before transport and controller.
      for (auto &[id, workspace] : workspaces) {
        workspace.runtime->changed = {};
        workspace.runtime->painted = {};
        workspace.tabs.clear();
      }

      workspaces.clear();
    }

    void schedule() {
      if (!update_timer.isActive()) {
        update_timer.start(0);
      }
    }

    void notify() {
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

    View &createSurface(Workspace &workspace,
                        Tab &tab,
                        Element element,
                        QVariantMap configuration = {},
                        std::uint64_t pane = 0) {
      if (tab.views.size() >= Layout::capacity) {
        throw std::runtime_error("Tab surface limit reached");
      }

      auto view = std::make_unique<View>();
      view->pane = pane;
      view->configuration = configuration;
      view->surface = std::make_unique<LuaSurface>(desktop,
                                                   QSize(320, 240),
                                                   ui::SurfaceKind::workbench,
                                                   configuration);
      auto &window = view->surface->window();
      window.setPersistentGraphics(false);
      window.setPersistentSceneGraph(false);
      window.setFlags(Qt::Window | Qt::FramelessWindowHint);
      window.setTitle(element.title.isEmpty() ? QStringLiteral("Telar Pane") : element.title);
      auto *raw = view.get();
      const auto id = element.id;
      if (pane) {
        view->terminal =
            std::make_unique<TerminalItem>(workspace.runtime->screen(pane), window.contentItem());
        view->terminal->setZ(1);
        view->terminal->send = [&runtime = *workspace.runtime, pane](const QByteArray &bytes) {
          runtime.input(pane, bytes);
        };

        view->terminal->resized = [&runtime = *workspace.runtime, pane](telar::TerminalSize size) {
          runtime.resize(pane, size);
        };

        view->terminal->scrolled = [&runtime = *workspace.runtime, pane](std::uint32_t offset) {
          runtime.viewport(pane, offset);
        };

        view->terminal->focused = [this, &tab, id] {
          if (tab.layout.focused() != id) {
            tab.layout.focus(id);
            schedule();
            save_timer.start();
          }
        };

        view->terminal->configure(options);
      }

      QObject::connect(&window, &QWindow::activeChanged, &window, [this, id, raw] {
        if (raw->surface->window().isActive()) {
          for (auto &[workspace_id, workspace] : workspaces) {
            for (auto &[tab_id, tab] : workspace.tabs) {
              if (tab.views.contains(id) && tab.layout.focused() != id) {
                tab.layout.focus(id);
                schedule();
              }
            }
          }

          if (raw->terminal) {
            raw->terminal->forceActiveFocus();
          }
        }
      });

      tab.layout.insert(std::move(element), tab.next_axis);
      auto &result = *view;
      tab.views.emplace(id, std::move(view));
      return result;
    }

    void synchronize(Workspace &workspace, std::uint64_t workspace_id) {
      const auto &snapshots = workspace.runtime->tabs();
      for (const auto &[tab_id, panes] : snapshots) {
        auto &tab = workspace.tabs[tab_id];
        // Empty here can mean its first snapshot has not arrived yet.
        if (tab_id != workspace.runtime->activeTab() || !workspace.runtime->hasSnapshot(tab_id)) {
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
            createSurface(workspace, tab, element, {}, pane);
            if (tab.focus_new) {
              tab.layout.focus(id);
              focus_pending = true;
              focus_workspace = workspace_id;
              tab.focus_new = false;
            }
          }
        }

        std::erase_if(tab.views, [&](const auto &entry) {
          if (entry.second->pane && !live.contains(entry.first)) {
            tab.layout.remove(entry.first);
            return true;
          }

          return false;
        });

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
              createSurface(workspace,
                            tab,
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
          return true;
        }

        return false;
      });
    }

    void hide(View &view) {
      if (!view.visible) {
        return;
      }

      if (view.surface) {
        view.surface->window().hide();
      }

      if (view.external) {
        view.external->show(false);
      }

      view.visible = false;
    }

    void present(Workspace &workspace, std::uint64_t workspace_id, bool reconfigure) {
      const auto gap = metric(options, "gap", default_gap);
      const auto padding = metric(options, "padding", default_padding);
      const auto header = metric(options, "header_height", default_header);
      const auto active_tab = workspace.runtime->activeTab();
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
        std::set<QString> shown;
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
              if (!view.external->alive()) {
                tab.layout.remove(placement.id);
                tab.views.erase(found);
                continue;
              }

              view.external->show(true);
              if (view.placed_space != workspace.space) {
                view.external->setSpace(workspace.space);
                view.placed_space = workspace.space;
              }

              if (view.applied != placement.frame || !view.visible) {
                view.actual = view.external->place(placement.frame);
                view.applied = placement.frame;
              } else if (view.external->geometryChanged()) {
                view.actual = view.external->frame();
              }
              if (!focus_pending && workspace.space == services.desktop.state().focused_space &&
                  view.external->focused() && tab.layout.focused() != placement.id) {
                tab.layout.focus(placement.id);
              }
            } else {
              auto &window = view.surface->window();
              const QRect geometry(
                  QPoint(qRound(placement.frame.left()), qRound(placement.frame.top())),
                  QSize(qRound(placement.frame.right()) - qRound(placement.frame.left()),
                        qRound(placement.frame.bottom()) - qRound(placement.frame.top())));
              if (window.geometry() != geometry) {
                window.setGeometry(geometry);
              }

              if (view.placed_space != workspace.space) {
                native::place(window, workspace.space);
                view.placed_space = workspace.space;
              }

              const bool selected = tab.layout.focused() == placement.id;
              view.surface->setNativeState(
                  {{"element", placement.id},
                   {"pane", view.pane ? QVariant(QString::number(view.pane)) : QVariant{}},
                   {"workspace", QString::number(workspace_id)},
                   {"tab", QString::number(tab_id)},
                   {"focused", selected},
                   {"floating", tab.layout.element(placement.id)->floating},
                   {"area", rectangle(workspace.area)},
                   {"geometry", rectangle(placement.frame)},
                   {"content",
                    rectangle(
                        QRectF(padding,
                               header,
                               std::max(0.0, placement.frame.width() - padding * 2),
                               std::max(0.0, placement.frame.height() - header - padding)))}});
              if (view.terminal) {
                if (reconfigure) {
                  view.terminal->configure(options);
                }

                view.terminal->setPosition({padding, header});
                view.terminal->setSize(
                    {std::max(0.0, placement.frame.width() - padding * 2),
                     std::max(0.0, placement.frame.height() - header - padding)});
              }

              window.show();
              if (view.shown_order != placement.order) {
                window.raise();
                view.shown_order = placement.order;
              }

              view.actual = window.geometry();
            }

            view.visible = true;
            view.error.clear();
          } catch (const std::exception &failure) {
            view.error = QString::fromUtf8(failure.what());
            if (view.surface) {
              view.surface->window().hide();
            }

            view.visible = false;
          }
        }

        for (auto &[id, view] : tab.views) {
          if (!shown.contains(id)) {
            try {
              hide(*view);
            } catch (const std::exception &failure) {
              view->error = QString::fromUtf8(failure.what());
            }
          }
        }
      }
    }

    void reconcile() {
      if (changing) {
        schedule();
        return;
      }

      changing = true;
      try {
        const auto configured = desktop.options(ui::SurfaceKind::workbench);
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

        for (const auto &space : services.desktop.state().spaces) {
          if (!space.workspace || !space.visible || space.fullscreen) {
            continue;
          }

          const auto id = *space.workspace;
          auto &workspace = workspaces[id];
          if (!workspace.runtime) {
            workspace.runtime = std::make_unique<RuntimeConnection>(
                QString::fromStdString(services.runtime_socket),
                telar::WorkspaceLocation{telar::WorkspaceLocation::Kind::workspace, id});
            workspace.runtime->changed = [this] {
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
          workspace.visible = true;
          if (catalog.workspace && catalog.workspace->id == id && catalog.active_tab) {
            if (workspace.runtime->activeTab() != catalog.active_tab && space.focused) {
              focus_pending = true;
            }

            workspace.runtime->selectTab(catalog.active_tab);
          }
        }

        for (auto &[id, workspace] : workspaces) {
          workspace.runtime->setVisible(workspace.visible);
          synchronize(workspace, id);
          present(workspace, id, reconfigure);
          for (const auto &[tab_id, tab] : workspace.tabs) {
            remember(id, tab_id, tab);
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

        if (focus_pending && focusCurrent()) {
          focus_pending = false;
          focus_workspace = 0;
        }

        error.clear();
      } catch (const std::exception &failure) {
        error = QString::fromUtf8(failure.what());
        qWarning() << "Workbench reconciliation failed:" << error;
      }

      changing = false;
      const auto current = state();
      if (notified_state != current) {
        notified_state = current;
        notify();
      }
    }

    bool focusCurrent() {
      auto *workspace = focusedWorkspace();
      if (focus_workspace && workspaces.contains(focus_workspace)) {
        workspace = &workspaces.at(focus_workspace);
      }

      if (!workspace || !workspace->visible) {
        return false;
      }

      const auto found = workspace->tabs.find(workspace->runtime->activeTab());
      if (found == workspace->tabs.end()) {
        return false;
      }

      auto &tab = found->second;
      const auto target = tab.views.find(tab.layout.focused());
      if (target == tab.views.end() || !target->second->visible) {
        return false;
      }

      auto &view = *target->second;
      if (view.external) {
        view.external->focus();
      } else {
        view.surface->window().raise();
        view.surface->window().requestActivate();
        if (view.terminal) {
          view.terminal->forceActiveFocus();
        }
      }

      return true;
    }

    QVariantMap state() const {
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

      const auto current = services.desktop.focusedWorkspace();
      return {{"workspace", current ? QVariant(QString::number(*current)) : QVariant{}},
              {"workspaces", workspace_list},
              {"error", error}};
    }

    QVariant command(const QString &action, const QVariantMap &args) {
      if (action == "windows") {
        return native::windows();
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
      } else if (action == "close") {
        const auto view = tab.views.find(id);
        if (view == tab.views.end()) {
          return false;
        }

        if (view->second->pane) {
          workspace->runtime->close(view->second->pane);
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
        createSurface(
            *workspace,
            tab,
            Element{view_id, ContentKind::view, args.value("title", "Telar View").toString()},
            {{"module", module}, {"options", args.value("options", QVariantMap{})}});
        tab.layout.focus(view_id);
        focus_pending = true;
        result = view_id;
      } else if (action == "adopt") {
        const auto window_id = identifier(args.value("window"));
        if (window_id > std::numeric_limits<std::uint32_t>::max()) {
          throw std::runtime_error("Invalid native window ID");
        }

        const auto element_id = "window:" + QString::number(window_id);
        for (const auto &[wid, existing] : workspaces) {
          for (const auto &[tid, candidate] : existing.tabs) {
            if (candidate.views.contains(element_id)) {
              throw std::runtime_error("Window already belongs to a tab");
            }
          }
        }

        if (tab.views.size() >= Layout::capacity) {
          throw std::runtime_error("Tab element limit reached");
        }

        auto view = std::make_unique<View>();
        view->external =
            std::make_unique<native::ExternalWindow>(static_cast<std::uint32_t>(window_id));
        view->external->setSpace(workspace->space);
        view->placed_space = workspace->space;
        view->actual = view->external->frame();
        tab.layout.insert(Element{element_id, ContentKind::external, view->external->title()});
        tab.views.emplace(element_id, std::move(view));
        result = element_id;
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
