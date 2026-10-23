#include "session.hpp"
#include <QGuiApplication>
#include <QInputMethod>
#include <QWindow>
#include <QVariant>
#include <algorithm>
#include <stdexcept>

namespace workbench::native {
  QRect frame(QWindow &window) {
    const auto resource = linux_desktop::target(window).resource;
    for (const auto &surface : linux_desktop::Session::get().snapshot().surfaces) {
      if (surface.resource == resource) {
        return surface.geometry;
      }
    }
    return window.geometry();
  }

  Display display(std::uint32_t identifier) {
    for (const auto &output : linux_desktop::Session::get().snapshot().outputs) {
      if (output.id == identifier) {
        return {output.available, output.scale};
      }
    }
    return {};
  }

  void setFrame(QWindow &window, QRect frame) {
    window.setProperty("telar_frame", frame);
    window.setGeometry(frame);
    const auto space = window.property("telar_space");
    if (space.isValid()) {
      linux_desktop::place(window, space.toULongLong(), TELAR_WINDOWS, true);
    }
  }

  void place(QWindow &window, std::uint64_t space) {
    window.setProperty("telar_space", QVariant::fromValue<qulonglong>(space));
    linux_desktop::place(window, space, TELAR_WINDOWS, true);
  }

  void raise(QWindow &window) {
    const auto target = linux_desktop::target(window);
    linux_desktop::Session::get().post([target](telar_server *server) {
      telar_server_raise(server, target);
    });
  }

  void setVisible(QWindow &window, bool visible) {
    window.setOpacity(visible ? 1 : 0);
    const auto target = linux_desktop::target(window);
    linux_desktop::Session::get().post([target, visible](telar_server *server) {
      telar_server_visible(server, target, visible);
    });
  }

  void prepareInputWindow(QWindow &) {}

  void commitComposition(QWindow &) {
    QGuiApplication::inputMethod()->commit();
  }

  struct WindowObserver::Impl {
    std::uint64_t subscription;
    ForeignWindows current;
    std::vector<linux_desktop::Surface> surfaces;
    Delivery deliver;

    explicit Impl(Delivery callback)
        : deliver(std::move(callback)) {
      subscription = linux_desktop::Session::get().subscribe([this](const auto &snapshot) {
        if (current != snapshot.windows || surfaces != snapshot.surfaces) {
          current = snapshot.windows;
          surfaces = snapshot.surfaces;
          deliver(current);
        }
      });
    }

    ~Impl() {
      linux_desktop::Session::get().unsubscribe(subscription);
    }
  };

  WindowObserver::WindowObserver(QObject &, Delivery deliver)
      : impl_(std::make_unique<Impl>(std::move(deliver))) {}

  WindowObserver::~WindowObserver() = default;

  void WindowObserver::place(std::uint32_t window, std::uint64_t space, QRectF frame) {
    const auto box = frame.toRect();
    const telar_placement placement{{window, 0},
                                    {box.x(), box.y(), box.width(), box.height()},
                                    space,
                                    TELAR_WINDOWS,
                                    true,
                                    true};
    linux_desktop::Session::get().post([placement](telar_server *server) {
      telar_server_place(server, &placement);
    });
  }

  void WindowObserver::move(std::uint32_t window, QPointF position) {
    const auto found = std::ranges::find(impl_->current.windows, window, &ForeignWindow::id);
    if (found != impl_->current.windows.end()) {
      place(window, found->space, {position, found->frame.size()});
    }
  }

  void WindowObserver::hide(std::uint32_t window, std::uint64_t) {
    linux_desktop::Session::get().post([window](telar_server *server) {
      telar_server_visible(server, {window, 0}, false);
    });
  }

  void WindowObserver::focus(std::uint32_t window) {
    linux_desktop::Session::get().post([window](telar_server *server) {
      telar_server_focus(server, {window, 0});
    });
  }

  void WindowObserver::sendToBackstage(std::uint32_t) {
    throw std::runtime_error("The backstage is not available on Linux yet");
  }

  void WindowObserver::takeOver(std::uint32_t, std::uint32_t, QRectF) {
    throw std::runtime_error("The backstage is not available on Linux yet");
  }

  void WindowObserver::endTakeover(std::uint32_t) {
    throw std::runtime_error("The backstage is not available on Linux yet");
  }

  void WindowObserver::close(std::uint32_t window) {
    linux_desktop::Session::get().post([window](telar_server *server) {
      telar_server_close(server, {window, 0});
    });
  }
} // namespace workbench::native
