#include "../application.hpp"
#include "../shortcuts.hpp"
#include "session.hpp"
#include "session_services.hpp"
#include "../../desktop_registry.hpp"
#include "../../ui/services.hpp"
#include "../../ui/desktop_ui.hpp"
#include "../../ui/lua_surface.hpp"
#include "../../ui/workbench/controller.hpp"
#include <QGuiApplication>
#include <QLockFile>
#include <QScreen>
#include <QSocketNotifier>
#include <QTimer>
#include <sys/eventfd.h>
#include <sys/signalfd.h>
#include <signal.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <stdexcept>

namespace {
  class Signals final {
  public:
    Signals() {
      sigemptyset(&mask_);
      for (const int signal : {SIGINT, SIGTERM, SIGHUP, SIGCHLD}) {
        sigaddset(&mask_, signal);
      }
      if (pthread_sigmask(SIG_BLOCK, &mask_, &previous_) != 0) {
        throw std::runtime_error("Cannot install session signal handling");
      }
      sigdelset(&mask_, SIGCHLD);
      fd = signalfd(-1, &mask_, SFD_CLOEXEC | SFD_NONBLOCK);
      if (fd < 0) {
        pthread_sigmask(SIG_SETMASK, &previous_, nullptr);
        throw std::runtime_error("Cannot create session signal descriptor");
      }
    }

    ~Signals() {
      close(fd);
      pthread_sigmask(SIG_SETMASK, &previous_, nullptr);
    }

    int fd;

  private:
    sigset_t mask_, previous_;
  };

} // namespace

struct ApplicationWakeup::Impl {
  // Created before runtime workers so every thread inherits the signal mask.
  Signals signal_guard;
  int fd = -1;
};

ApplicationWakeup::ApplicationWakeup()
    : impl(new Impl) {
  impl->fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (impl->fd < 0) {
    delete impl;
    throw std::runtime_error("Cannot create application wakeup");
  }
}

ApplicationWakeup::~ApplicationWakeup() {
  close(impl->fd);
  delete impl;
}

void ApplicationWakeup::wakeup() noexcept {
  const std::uint64_t value = 1;
  while (write(impl->fd, &value, sizeof(value)) < 0 && errno == EINTR) {
  }
}

namespace {
  constexpr int topbar_height = 36;
  constexpr int sidebar_width = 280;
  constexpr int panel_margin = 8;

  QVariantMap rectangle(QRect rectangle) {
    return {{"x", rectangle.x()},
            {"y", rectangle.y()},
            {"width", rectangle.width()},
            {"height", rectangle.height()}};
  }

  class Panels final {
  public:
    explicit Panels(ui::DesktopUi &desktop)
        : desktop_(desktop) {
      subscription_ = linux_desktop::Session::get().subscribe([this](const auto &snapshot) {
        reconcile(snapshot.outputs);
      });
    }

    ~Panels() {
      linux_desktop::Session::get().unsubscribe(subscription_);
    }

  private:
    ui::DesktopUi &desktop_;
    std::uint64_t subscription_ = 0;
    std::vector<linux_desktop::Output> outputs_;
    std::map<std::pair<std::uint32_t, ui::SurfaceKind>, std::unique_ptr<LuaSurface>> surfaces_;

    void reconcile(const std::vector<linux_desktop::Output> &outputs) {
      // Workspace switches do not rebuild panel surfaces.
      auto geometry = outputs;
      for (auto &output : geometry) {
        output.space = 0;
      }
      if (outputs_ == geometry) {
        return;
      }
      outputs_ = geometry;
      std::erase_if(surfaces_, [&](const auto &entry) {
        return std::ranges::none_of(outputs, [&](const auto &output) {
          return output.id == entry.first.first;
        });
      });
      constexpr std::array kinds{ui::SurfaceKind::wallpaper,
                                 ui::SurfaceKind::topbar,
                                 ui::SurfaceKind::sidebar};
      for (const auto &output : outputs) {
        for (const auto kind : kinds) {
          QRect frame = kind == ui::SurfaceKind::wallpaper ? output.geometry : output.available;
          if (kind == ui::SurfaceKind::topbar) {
            frame.setHeight(std::min(frame.height(), topbar_height));
          }
          if (kind == ui::SurfaceKind::sidebar) {
            frame.adjust(panel_margin, topbar_height + panel_margin, -panel_margin, -panel_margin);
            frame.setWidth(std::min(frame.width(), sidebar_width));
          }
          auto &surface = surfaces_[{output.id, kind}];
          if (!surface) {
            surface = std::make_unique<LuaSurface>(desktop_, frame.size(), kind);
            auto &window = surface->window();
            window.setFlags(Qt::Window | Qt::FramelessWindowHint);
            window.setTitle(kind == ui::SurfaceKind::wallpaper ? "Telar Wallpaper"
                            : kind == ui::SurfaceKind::topbar  ? "Telar Top Bar"
                                                               : "Telar Sidebar");
            surface->setFocusHandler([pointer = surface.get()] {
              linux_desktop::focus(pointer->window());
            });
          }
          auto &window = surface->window();
          for (auto *screen : QGuiApplication::screens()) {
            if (screen->name() == output.name) {
              window.setScreen(screen);
              break;
            }
          }
          workbench::native::setFrame(window, frame);
          surface->setNativeState({
              {"screen",
               QVariantMap{{"id", output.id},
                           {"name", output.name},
                           {"geometry", rectangle(output.geometry)},
                           {"available_geometry", rectangle(output.available)}}},
              {"geometry", rectangle(frame)},
              {"scale", output.scale},
              {"safe_area",
               QVariantMap{{"top", 0},
                           {"right", 0},
                           {"bottom", 0},
                           {"left", 0},
                           {"exclusions", QVariantList{}}}},
              {"visible", true},
              {"active", false},
          });
          window.show();
          linux_desktop::place(window,
                               0,
                               kind == ui::SurfaceKind::wallpaper ? TELAR_BACKGROUND
                                                                  : TELAR_OVERLAY,
                               kind != ui::SurfaceKind::wallpaper);
        }
      }
      for (const auto &output : outputs) {
        const QRect area = desktop_.workArea(output.id, output.available).toAlignedRect();
        linux_desktop::Session::get().post([id = output.id, area](telar_server *server) {
          telar_server_workarea(server, id, {area.x(), area.y(), area.width(), area.height()});
        });
      }
      if (desktop_.changed) {
        desktop_.changed();
      }
    }
  };
} // namespace

int runApplication(ApplicationHost &host,
                   ApplicationWakeup &wakeup,
                   const AppState &,
                   ui::Services &services) {
  // Replacing a running compositor would disconnect every graphical application.
  QLockFile lock(QString::fromStdString(DesktopRegistry::directory() + "/control.lock"));
  lock.setStaleLockTime(0);
  if (!lock.tryLock()) {
    throw std::runtime_error("A Telar Desktop session is already running");
  }

  const auto backends = qEnvironmentVariable("WLR_BACKENDS");
  const bool standalone = !qEnvironmentVariableIsSet("WAYLAND_DISPLAY") &&
                          !qEnvironmentVariableIsSet("DISPLAY") && !backends.contains("headless") &&
                          !backends.contains("wayland") && !backends.contains("x11");
  linux_desktop::Session compositor;
  linux_desktop::SessionServices::prepare(standalone);
  int argc = 1;
  char application_name[] = "telar-desktop";
  char *argv[] = {application_name, nullptr};
  QGuiApplication application(argc, argv);
  application.setDesktopFileName("telar-desktop");
  application.setQuitOnLastWindowClosed(false);
  compositor.attach();
  linux_desktop::SessionServices session_services(standalone);
  QSocketNotifier termination(wakeup.impl->signal_guard.fd, QSocketNotifier::Read);
  QObject::connect(&termination, &QSocketNotifier::activated, &application, [&] {
    signalfd_siginfo info;
    while (read(wakeup.impl->signal_guard.fd, &info, sizeof(info)) > 0) {
    }
    if (host.requestExit()) {
      application.quit();
    }
  });
  QSocketNotifier notifier(wakeup.impl->fd, QSocketNotifier::Read);
  QObject::connect(&notifier, &QSocketNotifier::activated, &application, [&] {
    std::uint64_t value;
    while (read(wakeup.impl->fd, &value, sizeof(value)) > 0 || errno == EINTR) {
    }
    if (!host.update()) {
      application.quit();
    }
  });

  struct Lifecycle {
    ApplicationHost &host;

    ~Lifecycle() {
      host.stop();
    }
  } lifecycle{host};

  host.start();
  if (!host.update()) {
    return EXIT_FAILURE;
  }
  ui::DesktopUi desktop_ui(services);
  Panels panels(desktop_ui);
  NativeShortcuts shortcuts(services.shortcuts);
  workbench::Controller workbench(desktop_ui);
  return host.update() ? application.exec() : EXIT_FAILURE;
}
