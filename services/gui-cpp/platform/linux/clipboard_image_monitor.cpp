#include "platform/clipboard_image_monitor.hpp"
#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_file.h"
#include "platform/clipboard_image_source.hpp"
#include "platform/file_descriptor.hpp"
#include "memory/allocator.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtconfigmacros.h>
#include <QtGui/qguiapplication_platform.h>
#include <QtWaylandClient/private/qwayland-wayland.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <wayland-client-core.h>
#include <QtWaylandClient/private/wayland-wayland-client-protocol.h>
#include <wayland-util.h>

namespace telar::gui::platform {

struct ClipboardImageMonitor::Native final {
  class Registry final : public QtWayland::wl_registry {
  public:
    explicit Registry(Native &owner) : owner_(owner) {}
    ~Registry() override = default;
    Registry(const Registry &) = delete;
    Registry &operator=(const Registry &) = delete;
    Registry(Registry &&) = delete;
    Registry &operator=(Registry &&) = delete;

  protected:
    void registry_global(std::uint32_t name, const QString &interface, std::uint32_t version) override {
      owner_.global(name, interface, version);
    }

  private:
    Native &owner_;
  };

  class Device final : public QtWayland::wl_data_device {
  public:
    explicit Device(Native &owner) : owner_(owner) {}
    ~Device() override = default;
    Device(const Device &) = delete;
    Device &operator=(const Device &) = delete;
    Device(Device &&) = delete;
    Device &operator=(Device &&) = delete;

  protected:
    void data_device_data_offer(::wl_data_offer *handle) override {
      owner_.offered(handle);
    }

    void data_device_selection(::wl_data_offer *handle) override {
      owner_.select(handle);
    }

    void data_device_enter(std::uint32_t /*serial*/, ::wl_surface * /*surface*/, wl_fixed_t /*x*/, wl_fixed_t /*y*/, ::wl_data_offer *handle) override {
      owner_.entered(handle);
    }

  private:
    Native &owner_;
  };

  struct Offer final : QtWayland::wl_data_offer {
    Offer() = default;
    ~Offer() override { clear(); }
    Offer(const Offer &) = delete;
    Offer &operator=(const Offer &) = delete;
    Offer(Offer &&) = delete;
    Offer &operator=(Offer &&) = delete;

    void clear() noexcept {
      if (isInitialized()) {
        destroy();
      }

      png = false;
    }

  protected:
    void data_offer_offer(const QString &format) override {
      png = png || format == QStringLiteral("image/png");
    }

  public:
    bool png = false;
  };

  Native(::wl_display *display, ::wl_seat *seat)
      : display_(display),
        seat_(seat),
        registry_(*this),
        device_(*this) {
    auto *const registry = wl_display_get_registry(display_);
    if (registry == nullptr) {
      failed_ = true;

      return;
    }

    registry_.init(registry);
    flush();
  }

  ~Native() {
    for (auto &offer : offers_) {
      offer.clear();
    }

    if (device_.isInitialized()) {
      if (device_.version() >= WL_DATA_DEVICE_RELEASE_SINCE_VERSION) {
        device_.release();
      } else {
        wl_data_device_destroy(device_.object());
      }
    }

    if (manager_ != nullptr) {
      wl_data_device_manager_destroy(manager_);
    }

    if (registry_.isInitialized()) {
      wl_registry_destroy(registry_.object());
    }
  }

  Native(const Native &) = delete;
  Native &operator=(const Native &) = delete;
  Native(Native &&) = delete;
  Native &operator=(Native &&) = delete;

  [[nodiscard]] runtime::FileDescriptor capture() {
    if (failed_) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    if (selected_ == nullptr || !selected_->png) {
      throw ClipboardImageFailure{ClipboardImageError::no_image};
    }

    TelarGuiClipboardImagePipe descriptors{};
    if (telarGuiOpenClipboardImagePipe(&descriptors) != 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    runtime::FileDescriptor reading{descriptors.read_descriptor};
    const runtime::FileDescriptor writing{descriptors.write_descriptor};
    selected_->receive(QStringLiteral("image/png"), writing.get());
    flush();
    if (failed_) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    return reading;
  }

private:
  void flush() noexcept {
    failed_ = failed_ || (wl_display_flush(display_) < 0 && errno != EAGAIN);
  }

  void global(std::uint32_t name, const QString &interface, std::uint32_t version) {
    if (manager_ != nullptr || interface != QStringLiteral("wl_data_device_manager")) {
      return;
    }

    constexpr std::uint32_t maximum_version = 3;
    manager_ = static_cast<::wl_data_device_manager *>(registry_.bind(name, &wl_data_device_manager_interface, std::min(version, maximum_version)));
    if (manager_ == nullptr) {
      failed_ = true;

      return;
    }

    auto *const device = wl_data_device_manager_get_data_device(manager_, seat_);
    if (device == nullptr) {
      failed_ = true;

      return;
    }

    device_.init(device);
    flush();
  }

  void offered(::wl_data_offer *handle) {
    auto *const available = std::ranges::find_if(offers_, [](const auto &offer) { return !offer.isInitialized(); });
    if (available == offers_.end()) {
      wl_data_offer_destroy(handle);
      failed_ = true;

      return;
    }

    available->init(handle);
  }

  void select(::wl_data_offer *handle) {
    Offer *next = nullptr;
    for (auto &offer : offers_) {
      if (offer.isInitialized() && offer.object() == handle) {
        next = &offer;
      }
    }

    if (selected_ != nullptr && selected_ != next) {
      selected_->clear();
    }

    selected_ = next;
  }

  void entered(::wl_data_offer *handle) {
    for (auto &offer : offers_) {
      if (offer.isInitialized() && offer.object() == handle && &offer != selected_) {
        offer.clear();
      }
    }
  }

  static constexpr std::size_t maximum_pending_offers = 4;
  ::wl_display *display_;
  ::wl_seat *seat_;
  Registry registry_;
  Device device_;
  ::wl_data_device_manager *manager_ = nullptr;
  std::array<Offer, maximum_pending_offers> offers_;
  Offer *selected_ = nullptr;
  bool failed_ = false;
};

ClipboardImageMonitor::ClipboardImageMonitor(ApplicationAllocator &memory)
    : memory_(memory),
      native_(nullptr, runtime::AllocationDeleter<Native, ApplicationAllocator>{memory}) {
#if QT_CONFIG(xcb)
  if (qGuiApp->nativeInterface<QNativeInterface::QX11Application>() != nullptr) {
    xcb_.emplace(memory_);
  }
#endif

#if QT_CONFIG(wayland)
  if (const auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>(); native != nullptr && native->seat() != nullptr) {
    native_ = makeOwned<Native>(memory_, native->display(), native->seat());
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

  if (native_ && board != nullptr && !board->ownsClipboard()) {
    return ClipboardImageSource::fromPipe(memory_, native_->capture());
  }

  return ClipboardImageSource::snapshot(memory_);
}

}
