#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "xcb_clipboard_image_monitor.hpp"
#include "../../application/dependencies.hpp"
#include "../../attachments/secure_erase.hpp"
#include "../../attachments/types.hpp"
#include "../../core/memory.hpp"
#include "../../attachments/sensitive_bytes.hpp"
#include "../clipboard_image_source.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <poll.h>
#include <span>
#include <stdexcept>
#include <time.h>
#include <unistd.h>
#include <atomic>
#include <optional>
#include "telar_base/memory/allocator.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <QAbstractNativeEventFilter>
#include <QByteArray>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QObject>
#include <QTimer>
#include <QtCore/qtconfigmacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qguiapplication_platform.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string_view>
#include <sys/socket.h>
#include <utility>
#include <xcb/xcb.h>
#include <xcb/xcbext.h>
#include <xcb/xproto.h>

#include "application/dependencies.hpp"
#include "attachments/secure_erase.hpp"
#include "attachments/types.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_source.hpp"


import telar.gui.platform.profile_file;

namespace telar::gui::platform {

struct XcbClipboardImageMonitor::Native final : QAbstractNativeEventFilter {
  enum class Atom : std::uint8_t { clipboard, png, incremental, property, timestamp, count };
  enum class Phase : std::uint8_t { idle, snapshot, selection, property, writing, increment };
  static constexpr std::size_t atom_count = static_cast<std::size_t>(Atom::count);
  static constexpr std::size_t chunk_bytes = std::size_t{16} * 1024;
  static constexpr std::uint32_t property_unit_bytes = 4;
  static constexpr std::uint8_t byte_format = 8;
  static constexpr std::uint8_t integer_format = 32;
  static constexpr std::uint8_t event_type_mask = 0x7f;

  using Free = decltype(&std::free);

  struct EraseProperty {
    void operator()(xcb_get_property_reply_t *reply) const noexcept {
      const std::unique_ptr<xcb_get_property_reply_t, Free> ownership{reply, &std::free};
      if (reply != nullptr) {
        const auto length = xcb_get_property_value_length(reply);
        if (length > 0) {
          eraseSensitiveBytes(std::span{static_cast<std::byte *>(xcb_get_property_value(reply)), static_cast<std::size_t>(length)});
        }

      }
    }
  };

  explicit Native(ApplicationAllocator &memory) : memory_(memory) {
#if QT_CONFIG(xcb)
    const auto *const native = qGuiApp->nativeInterface<QNativeInterface::QX11Application>();
    connection_ = native != nullptr ? native->connection() : nullptr;
#endif
    if (connection_ == nullptr) {
      return;
    }

    constexpr std::array names{std::string_view{"CLIPBOARD"}, std::string_view{"image/png"}, std::string_view{"INCR"}, std::string_view{"_TELAR_CLIPBOARD_IMAGE"}, std::string_view{"_TELAR_CLIPBOARD_TIME"}};
    for (std::size_t index = 0; index < names.size(); ++index) {
      cookies_[index] = xcb_intern_atom(connection_, 0, static_cast<std::uint16_t>(names[index].size()), names[index].data()).sequence;
    }

    QObject::connect(&poller_, &QTimer::timeout, &poller_, [this] { advance(); });
    QCoreApplication::instance()->installNativeEventFilter(this);
    poller_.start(std::chrono::milliseconds{1});
    xcb_flush(connection_);
  }

  ~Native() override {
    poller_.stop();
    QCoreApplication::instance()->removeNativeEventFilter(this);
    finish(ClipboardImageError::read_failed);
    for (const auto cookie : cookies_) {
      discard(cookie);
    }
  }

  Native(const Native &) = delete;
  Native &operator=(const Native &) = delete;
  Native(Native &&) = delete;
  Native &operator=(Native &&) = delete;

  [[nodiscard]] std::pair<runtime::FileDescriptor, std::shared_ptr<ClipboardImageTransfer>> capture() {
    if (connection_ == nullptr || initialization_failed_ || xcb_connection_has_error(connection_) != 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    finish(ClipboardImageError::changed);
    std::array<int, 2> sockets{};
    if (::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sockets.data()) != 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    runtime::FileDescriptor reading{sockets.front()};
    writing_ = runtime::FileDescriptor{sockets.back()};
    status_ = std::allocate_shared<ClipboardImageTransfer>(AllocatorRef<ClipboardImageTransfer, ApplicationAllocator>{memory_});
    window_ = xcb_generate_id(connection_);
    const auto *const screen = xcb_setup_roots_iterator(xcb_get_setup(connection_)).data;
    constexpr std::uint32_t events = XCB_EVENT_MASK_PROPERTY_CHANGE;
    xcb_create_window(connection_, XCB_COPY_FROM_PARENT, window_, screen->root, 0, 0, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_ONLY, XCB_COPY_FROM_PARENT, XCB_CW_EVENT_MASK, &events);
    deadline_ = std::chrono::steady_clock::now() + ClipboardImagePipe::timeout;
    phase_ = Phase::snapshot;
    poller_.start(std::chrono::milliseconds{1});
    auto status = status_;
    advance();

    return {std::move(reading), std::move(status)};
  }

  void cancel() noexcept {
    finish(ClipboardImageError::read_failed);
  }

  bool nativeEventFilter(const QByteArray &type, void *message, [[maybe_unused]] qintptr *result) override {
    if (window_ == XCB_WINDOW_NONE || type != QByteArrayLiteral("xcb_generic_event_t")) {
      return false;
    }

    const auto *const event = static_cast<const xcb_generic_event_t *>(message);
    const auto kind = event->response_type & event_type_mask;
    if (kind == XCB_SELECTION_NOTIFY) {
      xcb_selection_notify_event_t selection{};
      std::memcpy(&selection, event, sizeof(selection));
      if (selection.requestor == window_ && selection.selection == atom(Atom::clipboard) && selection.target == atom(Atom::png) && selection.time == timestamp_ && phase_ == Phase::selection) {
        if (selection.property == atom(Atom::property)) {
          requestProperty();
        } else {
          finish(ClipboardImageError::no_image);
        }
      }
    } else if (kind == XCB_PROPERTY_NOTIFY) {
      xcb_property_notify_event_t property{};
      std::memcpy(&property, event, sizeof(property));
      if (property.window == window_ && property.state == XCB_PROPERTY_NEW_VALUE) {
        if (property.atom == atom(Atom::timestamp) && phase_ == Phase::snapshot) {
          timestamp_ = property.time;
        } else if (property.atom == atom(Atom::property) && phase_ == Phase::increment) {
          requestProperty();
        }
      }
    }

    return false;
  }

private:
  [[nodiscard]] xcb_atom_t atom(Atom name) const noexcept { return atoms_[static_cast<std::size_t>(name)]; }

  void discard(unsigned int sequence) noexcept {
    if (connection_ != nullptr && sequence != 0) {
      xcb_discard_reply(connection_, sequence);
    }
  }

  [[nodiscard]] std::unique_ptr<void, Free> reply(unsigned int &sequence) {
    if (sequence == 0) {
      return {nullptr, &std::free};
    }

    void *value = nullptr;
    xcb_generic_error_t *error = nullptr;
    if (xcb_poll_for_reply(connection_, sequence, &value, &error) == 0) {
      return {nullptr, &std::free};
    }

    sequence = 0;
    const std::unique_ptr<xcb_generic_error_t, Free> failure{error, &std::free};
    if (failure || value == nullptr) {
      finish(ClipboardImageError::read_failed);
    }

    return std::unique_ptr<void, Free>{value, &std::free};
  }

  [[nodiscard]] bool initializeAtom(std::size_t index) {
    if (cookies_[index] == 0) {
      return atoms_[index] != XCB_ATOM_NONE;
    }

    const auto value = reply(cookies_[index]);
    if (!value) {
      initialization_failed_ = cookies_[index] == 0;
      if (initialization_failed_) {
        poller_.stop();
      }

      return false;
    }

    atoms_[index] = static_cast<const xcb_intern_atom_reply_t *>(value.get())->atom;

    return atoms_[index] != XCB_ATOM_NONE;
  }

  [[nodiscard]] bool initialize() {
    for (std::size_t index = 0; index < cookies_.size(); ++index) {
      if (!initializeAtom(index)) {
        return false;
      }
    }

    return true;
  }

  void advance() {
    if (connection_ == nullptr || initialization_failed_ || xcb_connection_has_error(connection_) != 0) {
      finish(ClipboardImageError::read_failed);
      poller_.stop();

      return;
    }

    if (phase_ != Phase::idle && std::chrono::steady_clock::now() >= deadline_) {
      finish(ClipboardImageError::read_failed);
    }

    if (!initialize()) {
      return;
    }

    switch (phase_) {
    case Phase::idle:
      poller_.stop();
      return;
    case Phase::snapshot:
      snapshot();
      break;
    case Phase::property:
      receive();
      break;
    case Phase::writing:
      drain();
      break;
    case Phase::selection:
    case Phase::increment:
      break;
    }
  }

  void snapshot() {
    if (!snapshot_started_) {
      snapshot_started_ = true;
      xcb_change_property(connection_, XCB_PROP_MODE_APPEND, window_, atom(Atom::timestamp), XCB_ATOM_INTEGER, integer_format, 0, nullptr);
      owner_cookie_ = xcb_get_selection_owner(connection_, atom(Atom::clipboard)).sequence;
      xcb_flush(connection_);
    }

    if (owner_ == XCB_WINDOW_NONE) {
      const auto value = reply(owner_cookie_);
      if (!value) {
        return;
      }

      owner_ = static_cast<const xcb_get_selection_owner_reply_t *>(value.get())->owner;
      if (owner_ == XCB_WINDOW_NONE) {
        finish(ClipboardImageError::no_image);

        return;
      }
    }

    if (timestamp_ != XCB_CURRENT_TIME) {
      xcb_convert_selection(connection_, window_, atom(Atom::clipboard), atom(Atom::png), atom(Atom::property), timestamp_);
      xcb_flush(connection_);
      phase_ = Phase::selection;
    }
  }

  void requestProperty() {
    property_cookie_ = xcb_get_property(connection_, 0, window_, atom(Atom::property), XCB_GET_PROPERTY_TYPE_ANY, offset_, chunk_bytes / property_unit_bytes).sequence;
    phase_ = Phase::property;
    xcb_flush(connection_);
  }

  void receive() {
    auto value = reply(property_cookie_);
    if (!value || phase_ == Phase::idle) {
      return;
    }

    property_.reset(static_cast<xcb_get_property_reply_t *>(value.release()));
    const auto length = static_cast<std::size_t>(xcb_get_property_value_length(property_.get()));
    if (!incremental_ && offset_ == 0 && property_->type == atom(Atom::incremental)) {
      beginIncrement(length);

      return;
    }

    if (property_->type != atom(Atom::png) || property_->format != byte_format || length > chunk_bytes) {
      finish(ClipboardImageError::read_failed);

      return;
    }

    if (length > AttachmentLimits::maximum_source_bytes - received_ || property_->bytes_after > AttachmentLimits::maximum_source_bytes - received_ - length) {
      finish(ClipboardImageError::source_bytes);

      return;
    }

    if (length > AttachmentLimits::maximum_png_bytes - received_ || property_->bytes_after > AttachmentLimits::maximum_png_bytes - received_ - length) {
      finish(ClipboardImageError::png_bytes);

      return;
    }

    sent_ = 0;
    phase_ = Phase::writing;
    drain();
  }

  void beginIncrement(std::size_t length) {
    if (property_->format != integer_format || length != sizeof(std::uint32_t) || property_->bytes_after != 0) {
      finish(ClipboardImageError::read_failed);

      return;
    }

    std::uint32_t minimum = 0;
    std::memcpy(&minimum, xcb_get_property_value(property_.get()), sizeof(minimum));
    if (minimum > AttachmentLimits::maximum_source_bytes) {
      finish(ClipboardImageError::source_bytes);
    } else if (minimum > AttachmentLimits::maximum_png_bytes) {
      finish(ClipboardImageError::png_bytes);
    } else {
      property_.reset();
      incremental_ = true;
      phase_ = Phase::increment;
      xcb_delete_property(connection_, window_, atom(Atom::property));
      xcb_flush(connection_);
    }
  }

  void drain() {
    const auto length = static_cast<std::size_t>(xcb_get_property_value_length(property_.get()));
    const auto *const bytes = static_cast<const std::byte *>(xcb_get_property_value(property_.get()));
    if (sent_ < length) {
      const auto count = ::send(writing_.get(), bytes + sent_, length - sent_, MSG_NOSIGNAL);
      if (count < 0 && (errno == EAGAIN || errno == EINTR)) {
        return;
      }

      if (count <= 0) {
        finish(ClipboardImageError::read_failed);

        return;
      }

      sent_ += static_cast<std::size_t>(count);
      if (sent_ != length) {
        return;
      }
    }

    received_ += length;
    const auto after = property_->bytes_after;
    property_.reset();
    if (after != 0) {
      if (length == 0 || length % property_unit_bytes != 0) {
        finish(ClipboardImageError::read_failed);

        return;
      }

      offset_ += static_cast<std::uint32_t>(length / property_unit_bytes);
      requestProperty();
    } else if (incremental_ && length != 0) {
      offset_ = 0;
      phase_ = Phase::increment;
      xcb_delete_property(connection_, window_, atom(Atom::property));
      xcb_flush(connection_);
    } else {
      finish(std::nullopt);
    }
  }

  void finish(std::optional<ClipboardImageError> failure) noexcept {
    if (status_ && failure) {
      status_->fail(*failure);
    }

    discard(owner_cookie_);
    discard(property_cookie_);
    owner_cookie_ = 0;
    property_cookie_ = 0;
    property_.reset();
    writing_ = runtime::FileDescriptor{};
    status_.reset();
    if (window_ != XCB_WINDOW_NONE && connection_ != nullptr) {
      xcb_destroy_window(connection_, window_);
      xcb_flush(connection_);
    }

    window_ = XCB_WINDOW_NONE;
    owner_ = XCB_WINDOW_NONE;
    timestamp_ = XCB_CURRENT_TIME;
    snapshot_started_ = false;
    incremental_ = false;
    offset_ = 0;
    received_ = 0;
    sent_ = 0;
    phase_ = Phase::idle;
  }

  ApplicationAllocator &memory_;
  xcb_connection_t *connection_ = nullptr;
  QTimer poller_;
  std::array<xcb_atom_t, atom_count> atoms_{};
  std::array<unsigned int, atom_count> cookies_{};
  std::shared_ptr<ClipboardImageTransfer> status_;
  runtime::FileDescriptor writing_;
  std::unique_ptr<xcb_get_property_reply_t, EraseProperty> property_;
  std::chrono::steady_clock::time_point deadline_;
  xcb_window_t window_ = XCB_WINDOW_NONE;
  xcb_window_t owner_ = XCB_WINDOW_NONE;
  xcb_timestamp_t timestamp_ = XCB_CURRENT_TIME;
  unsigned int owner_cookie_ = 0;
  unsigned int property_cookie_ = 0;
  std::uint32_t offset_ = 0;
  std::size_t received_ = 0;
  std::size_t sent_ = 0;
  Phase phase_ = Phase::idle;
  bool snapshot_started_ = false;
  bool incremental_ = false;
  bool initialization_failed_ = false;
};

XcbClipboardImageMonitor::XcbClipboardImageMonitor(ApplicationAllocator &memory)
    : memory_(memory),
      native_(makeOwned<Native>(memory, memory)) {}

XcbClipboardImageMonitor::~XcbClipboardImageMonitor() = default;

void XcbClipboardImageMonitor::cancel() noexcept {
  native_->cancel();
}

ClipboardImageSource XcbClipboardImageMonitor::capture() {
  auto [descriptor, status] = native_->capture();

  return ClipboardImageSource::fromPipe(memory_, std::move(descriptor), std::move(status));
}

}
