module;

// Qt generates its core protocol header from a wayland.xml newer than many
// systems' libwayland, under the same WAYLAND_CLIENT_PROTOCOL_H guard. It must
// come first: the scanner header below pulls in the system one otherwise, and
// Qt's private headers then miss the interfaces only the newer one declares.
#include <QtWaylandClient/private/qwaylanddisplay_p.h>
#include <QtWaylandClient/private/qwaylandwindow_p.h>

#include "../window.hpp"
// These C headers carry no __cplusplus guard of their own.
extern "C" {
#include "background_effect.h"
#include "ext-background-effect-v1-client-protocol.h"
}
#include <QAbstractEventDispatcher>
#include <QByteArray>
#include <QEvent>
#include <QGuiApplication>
#include <QObject>
#include <QPlatformSurfaceEvent>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QWindow>
#include <QtCore/qlogging.h>
#include <QtCore/qstringliteral.h>
#include <QtGui/qguiapplication_platform.h>
#include <cstdint>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

module telar.gui.platform.private_file_stamp;

import std;

namespace telar::gui::platform {
namespace {

class BackgroundEffect final : public QObject {
public:
  explicit BackgroundEffect(QWindow &window)
      : QObject(&window),
        window_(window) {
    window_.installEventFilter(this);
    if (const auto *dispatcher = QAbstractEventDispatcher::instance()) {
      connect(dispatcher, &QAbstractEventDispatcher::aboutToBlock, this, [this] {
        apply();
      });
    }
  }

  BackgroundEffect(const BackgroundEffect &) = delete;
  BackgroundEffect &operator=(const BackgroundEffect &) = delete;
  BackgroundEffect(BackgroundEffect &&) = delete;
  BackgroundEffect &operator=(BackgroundEffect &&) = delete;

  ~BackgroundEffect() override {
    if (synchronization_ != nullptr) {
      wl_callback_destroy(synchronization_);
    }
    telar_background_effect_deinit(&native_);
  }

  void set(WindowAppearance appearance) {
    appearance_ = appearance;
    apply();
  }

  bool eventFilter(QObject *watched, QEvent *event) override {
    if (watched == &window_ && event->type() == QEvent::PlatformSurface) {
      const auto *surface = dynamic_cast<const QPlatformSurfaceEvent *>(event);
      if (surface == nullptr) {
        return QObject::eventFilter(watched, event);
      }
      if (surface->surfaceEventType() == QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed) {
        releaseSurface();
      } else {
        QTimer::singleShot(0, this, [this] {
          apply();
        });
      }
    } else if (watched == &window_ && (event->type() == QEvent::Resize || event->type() == QEvent::Show || event->type() == QEvent::WindowStateChange)) {
      QTimer::singleShot(0, this, [this] {
        apply();
      });
    }
    return QObject::eventFilter(watched, event);
  }

private:
  using Display = QtWaylandClient::QWaylandDisplay;

  static void synchronized(void *data, wl_callback *callback, std::uint32_t /*serial*/) {
    auto &self = *static_cast<BackgroundEffect *>(data);
    if (self.synchronization_ != callback) {
      return;
    }
    wl_callback_destroy(callback);
    self.synchronization_ = nullptr;
    self.ready_ = true;
    self.apply();
  }

  void awaitCapabilities() {
    if (synchronization_ != nullptr) {
      wl_callback_destroy(synchronization_);
    }
    ready_ = false;
    synchronization_ = wl_display_sync(display_->wl_display());
    if (synchronization_ != nullptr) {
      static constexpr wl_callback_listener listener{.done = synchronized};
      wl_callback_add_listener(synchronization_, &listener, this);
      static_cast<void>(wl_display_flush(display_->wl_display()));
    }
  }

  void bind(const Display::RegistryGlobal &global) {
    if (global.interface != QStringLiteral("ext_background_effect_manager_v1")) {
      return;
    }
    const auto name = global.interface.toLatin1();
    telar_background_effect_global(&native_, global.id, name.constData());
  }

  void attachDisplay(Display &display) {
    display_ = &display;
    native_.registry = display.wl_registry();
    const auto *application = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
    native_.compositor = application->compositor();
    for (const auto &global : display.globals()) {
      bind(global);
    }
    connect(&display, &Display::globalAdded, this, [this](const Display::RegistryGlobal &global) {
      bind(global);
      if (global.interface == QStringLiteral("ext_background_effect_manager_v1")) {
        awaitCapabilities();
      }
    });
    connect(&display, &Display::globalRemoved, this, [this](const Display::RegistryGlobal &global) {
      telar_background_effect_remove(&native_, global.id);
    });
    awaitCapabilities();
  }

  void releaseSurface() {
    if (native_.effect != nullptr) {
      ext_background_effect_surface_v1_destroy(native_.effect);
      native_.effect = nullptr;
    }
    native_.surface = nullptr;
    native_.configured = false;
    native_.dirty = true;
  }

  [[nodiscard]] bool changed(telar_gui_viewport viewport) const noexcept {
    const bool opaque = appearance_.background_opacity >= 1;
    const bool blurred = !opaque && appearance_.background_blur > 0 && native_.manager != nullptr && (native_.capabilities & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR) != 0;
    return native_.dirty || !native_.configured || native_.opaque != opaque || native_.blurred != blurred || native_.width != viewport.width || native_.height != viewport.height;
  }

  void apply() {
    const auto *window = dynamic_cast<const QtWaylandClient::QWaylandWindow *>(window_.handle());
    if (window == nullptr || window->wlSurface() == nullptr) {
      return;
    }
    if (display_ == nullptr) {
      attachDisplay(*window->display());
    }
    if (native_.surface != window->wlSurface()) {
      releaseSurface();
      native_.surface = window->wlSurface();
    }
    if (!ready_ || native_.compositor == nullptr) {
      return;
    }
    const auto size = window->surfaceSize();
    const telar_gui_viewport viewport{.width = static_cast<std::uint32_t>(std::max(1, size.width())), .height = static_cast<std::uint32_t>(std::max(1, size.height())), .scale = 1, .controls = 0};
    if (!changed(viewport)) {
      return;
    }
    if (telar_background_effect_apply(&native_, viewport, appearance_.background_opacity, appearance_.background_blur)) {
      if (auto *quick = qobject_cast<QQuickWindow *>(&window_)) {
        quick->update();
      } else {
        window_.requestUpdate();
      }
    } else if (!failed_) {
      qWarning("telar gui: background effect allocation failed; keeping transparency");
      failed_ = true;
    }
  }

  QWindow &window_;
  WindowAppearance appearance_;
  telar_background_effect native_{};
  Display *display_ = nullptr;
  wl_callback *synchronization_ = nullptr;
  bool ready_ = false;
  bool failed_ = false;
};

}

void configureBackgroundEffect(QWindow &window, WindowAppearance appearance) {
  for (auto *child : window.children()) {
    if (auto *effect = dynamic_cast<BackgroundEffect *>(child)) {
      effect->set(appearance);
      return;
    }
  }
  auto effect = std::make_unique<BackgroundEffect>(window);
  effect->set(appearance);
  std::ignore = effect.release();
}

}
