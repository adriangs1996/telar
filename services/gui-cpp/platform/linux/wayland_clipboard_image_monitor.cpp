#include "wayland_clipboard_image_monitor.hpp"
#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_file.h"
#include "platform/clipboard_image_source.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <QString>
#include <QtCore/qstringliteral.h>
#include <QtWaylandClient/private/qwayland-wayland.h>
#include <QtWaylandClient/private/wayland-wayland-client-protocol.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <wayland-client-core.h>
#include <wayland-util.h>

namespace telar::gui::platform {

struct WaylandClipboardImageMonitor::Native final {
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

    void registry_global_remove(std::uint32_t name) override {
      owner_.remove(name);
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

  explicit Native(::wl_display *display)
      : display_(display),
        registry_(*this) {
    auto *const registry = wl_display_get_registry(display_);
    if (registry == nullptr) {
      failed_ = true;

      return;
    }

    registry_.init(registry);
    flush();
  }

  ~Native() {
    clearDevice();
    clearSeat();
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

  [[nodiscard]] bool acceptsLocalSelection(std::uint32_t seat_global) const noexcept {
    return !failed_ && !binding_retired_ && seat_global != 0 && seat_global_ == seat_global && selected_ != nullptr && selected_->png;
  }

private:
  void flush() noexcept {
    failed_ = failed_ || (wl_display_flush(display_) < 0 && errno != EAGAIN);
  }

  void clearDevice() noexcept {
    select(nullptr);
    if (device_) {
      if (device_->version() >= WL_DATA_DEVICE_RELEASE_SINCE_VERSION) {
        device_->release();
      } else {
        wl_data_device_destroy(device_->object());
      }

      device_.reset();
    }
  }

  void clearSeat() noexcept {
    if (seat_) {
      if (seat_->version() >= WL_SEAT_RELEASE_SINCE_VERSION) {
        seat_->release();
      } else {
        wl_seat_destroy(seat_->object());
      }

      seat_.reset();
    }
  }

  void bindDevice() {
    if (device_ || manager_ == nullptr || !seat_) {
      return;
    }

    auto *const device = wl_data_device_manager_get_data_device(manager_, seat_->object());
    if (device == nullptr) {
      failed_ = true;

      return;
    }

    device_.emplace(*this);
    device_->init(device);
    flush();
  }

  void global(std::uint32_t name, const QString &interface, std::uint32_t version) {
    if (!seat_ && interface == QStringLiteral("wl_seat")) {
      constexpr std::uint32_t maximum_seat_version = 8;
      auto *const seat = static_cast<::wl_seat *>(registry_.bind(name, &wl_seat_interface, std::min(version, maximum_seat_version)));
      if (seat == nullptr) {
        failed_ = true;

        return;
      }

      seat_.emplace();
      seat_->init(seat);
      seat_global_ = name;
    } else if (manager_ == nullptr && interface == QStringLiteral("wl_data_device_manager")) {
      constexpr std::uint32_t maximum_manager_version = 3;
      manager_ = static_cast<::wl_data_device_manager *>(registry_.bind(name, &wl_data_device_manager_interface, std::min(version, maximum_manager_version)));
      if (manager_ == nullptr) {
        failed_ = true;

        return;
      }

      manager_global_ = name;
    }

    bindDevice();
    flush();
  }

  void remove(std::uint32_t name) noexcept {
    if (name != seat_global_ && name != manager_global_) {
      return;
    }

    binding_retired_ = true;
    clearDevice();
    if (name == seat_global_) {
      clearSeat();
      seat_global_ = 0;
    }

    if (name == manager_global_) {
      wl_data_device_manager_destroy(manager_);
      manager_ = nullptr;
      manager_global_ = 0;
    }

    flush();
  }

  void offered(::wl_data_offer *handle) {
    auto *const available = std::ranges::find_if(offers_, [](const auto &offer) { return !offer.isInitialized(); });
    if (available == offers_.end()) {
      wl_data_offer_destroy(handle);

      return;
    }

    available->init(handle);
  }

  void select(::wl_data_offer *handle) noexcept {
    selected_ = nullptr;
    for (auto &offer : offers_) {
      if (handle != nullptr && offer.isInitialized() && offer.object() == handle) {
        selected_ = &offer;
      } else {
        offer.clear();
      }
    }
  }

  void entered(::wl_data_offer *handle) {
    for (auto &offer : offers_) {
      if (offer.isInitialized() && offer.object() == handle && &offer != selected_) {
        offer.clear();
      }
    }
  }

  static constexpr std::size_t maximum_pending_offers = 16;
  ::wl_display *display_;
  Registry registry_;
  std::optional<Device> device_;
  std::optional<QtWayland::wl_seat> seat_;
  std::uint32_t seat_global_ = 0;
  std::uint32_t manager_global_ = 0;
  ::wl_data_device_manager *manager_ = nullptr;
  std::array<Offer, maximum_pending_offers> offers_;
  Offer *selected_ = nullptr;
  bool failed_ = false;
  bool binding_retired_ = false;
};

WaylandClipboardImageMonitor::WaylandClipboardImageMonitor(ApplicationAllocator &memory, ::wl_display *display)
    : native_(nullptr, runtime::AllocationDeleter<Native, ApplicationAllocator>{memory}) {
  if (display != nullptr) {
    native_ = makeOwned<Native>(memory, display);
  }
}

WaylandClipboardImageMonitor::~WaylandClipboardImageMonitor() = default;

bool WaylandClipboardImageMonitor::available() const noexcept {
  return native_ != nullptr;
}

runtime::FileDescriptor WaylandClipboardImageMonitor::capture() {
  if (!native_) {
    throw ClipboardImageFailure{ClipboardImageError::no_image};
  }

  return native_->capture();
}

bool WaylandClipboardImageMonitor::acceptsLocalSelection(std::uint32_t seat_global) const noexcept {
  return native_ != nullptr && native_->acceptsLocalSelection(seat_global);
}

}
