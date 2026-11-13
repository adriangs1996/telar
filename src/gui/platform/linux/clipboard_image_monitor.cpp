#include "platform/clipboard_image_monitor.hpp"
#include "application/dependencies.hpp"
#include "platform/clipboard_image_source.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QtCore/qtconfigmacros.h>
#include <QtGui/qguiapplication_platform.h>
#include <QtWaylandClient/private/qwayland-wayland.h>
#include <QtWaylandClient/private/qwaylandinputdevice_p.h>
#include <cstdint>

namespace telar::gui::platform {

namespace {

std::uint32_t qtSeatGlobal() noexcept {
#if QT_CONFIG(wayland)
  const auto *const native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
  if (native != nullptr && native->seat() != nullptr) {
    const auto *const seat = QtWayland::wl_seat::fromObject(native->seat());
    const auto *const input = dynamic_cast<const QtWaylandClient::QWaylandInputDevice *>(seat);
    if (input != nullptr) {
      return input->id();
    }
  }
#endif

  return 0;
}

::wl_display *waylandDisplay() noexcept {
#if QT_CONFIG(wayland)
  if (const auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>()) {
    return native->display();
  }
#endif

  return nullptr;
}

}

ClipboardImageMonitor::ClipboardImageMonitor(ApplicationAllocator &memory)
    : memory_(memory),
      native_(memory, waylandDisplay()) {
#if QT_CONFIG(xcb)
  if (qGuiApp->nativeInterface<QNativeInterface::QX11Application>() != nullptr) {
    xcb_.emplace(memory_);
  }
#endif

}

ClipboardImageMonitor::~ClipboardImageMonitor() = default;

void ClipboardImageMonitor::cancel() noexcept {
  if (xcb_) {
    xcb_->cancel();
  }
}

ClipboardImageSource ClipboardImageMonitor::snapshot() {
  const auto *const board = QGuiApplication::clipboard();
  if (xcb_ && board != nullptr && !board->ownsClipboard()) {
    return xcb_->capture();
  }

  if (native_.available()) {
    if (board != nullptr && board->ownsClipboard() && native_.acceptsLocalSelection(qtSeatGlobal())) {
      return ClipboardImageSource::snapshot(memory_);
    }

    return ClipboardImageSource::fromPipe(memory_, native_.capture());
  }

  return ClipboardImageSource::snapshot(memory_);
}

}
