#include "platform/clipboard_image_source.hpp"
#include "application/dependencies.hpp"
#include "attachments/catalog.hpp"
#include "attachments/secure_erase.hpp"
#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"
#include "core/memory.hpp"
#include "memory/allocator.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QBuffer>
#include <QClipboard>
#include <QGuiApplication>
#include <QImageReader>
#include <QIODevice>
#include <QMimeData>
#include <QSize>
#include <QString>
#include <cstddef>
#include <cstdint>
#include <span>
#include <utility>

namespace telar::gui::platform {

namespace {

struct Transfer {
  ApplicationAllocator &memory;
  SensitiveBytes<ApplicationAllocator> png;
};

void erase(QByteArray &bytes) noexcept {
  eraseSensitiveBytes(std::as_writable_bytes(std::span{bytes.data(), static_cast<std::size_t>(bytes.size())}));
}

}

ClipboardImageSource::ClipboardImageSource(void *native, std::int64_t revision) noexcept
    : native_(native),
      revision_(revision) {}

ClipboardImageSource ClipboardImageSource::snapshot(ApplicationAllocator &memory) {
  const auto *const board = QGuiApplication::clipboard();
  const auto *const mime = board == nullptr ? nullptr : board->mimeData();
  if (mime == nullptr || !mime->hasFormat(QStringLiteral("image/png"))) {
    throw ClipboardImageFailure{ClipboardImageError::no_image};
  }

  // Qt owns selection negotiation on its GUI thread. Keep the encoded transfer;
  // metadata validation and all decoding remain on the media worker.
  QByteArray encoded = mime->data(QStringLiteral("image/png"));
  auto transfer = makeOwned<Transfer>(memory, Transfer{.memory = memory, .png = SensitiveBytes{memory}});
  try {
    if (encoded.isEmpty()) {
      throw ClipboardImageFailure{ClipboardImageError::no_image};
    }

    if (std::cmp_greater(encoded.size(), AttachmentLimits::maximum_source_bytes)) {
      throw ClipboardImageFailure{ClipboardImageError::source_bytes};
    }

    transfer->png.append(std::as_bytes(std::span{encoded.constData(), static_cast<std::size_t>(encoded.size())}), AttachmentLimits::maximum_png_bytes);
  } catch (...) {
    erase(encoded);
    throw;
  }

  erase(encoded);

  return ClipboardImageSource{transfer.release(), 0};
}

ClipboardImageSource::~ClipboardImageSource() {
  clear();
}

ClipboardImageSource::ClipboardImageSource(ClipboardImageSource &&other) noexcept
    : native_(std::exchange(other.native_, nullptr)),
      revision_(other.revision_) {}

ClipboardImageSource &ClipboardImageSource::operator=(ClipboardImageSource &&other) noexcept {
  if (this != &other) {
    clear();
    native_ = std::exchange(other.native_, nullptr);
    revision_ = other.revision_;
  }

  return *this;
}

void ClipboardImageSource::clear() noexcept {
  if (native_ != nullptr) {
    auto *const transfer = static_cast<Transfer *>(native_);
    runtime::AllocationDeleter<Transfer, ApplicationAllocator>{transfer->memory}(transfer);
    native_ = nullptr;
  }
}

AttachmentCapture<ApplicationAllocator> ClipboardImageSource::read(ApplicationAllocator &memory, ClipboardCaptureRequest request) const {
  if (native_ == nullptr) {
    throw ClipboardImageFailure{ClipboardImageError::no_image};
  }

  const auto &transfer = *static_cast<const Transfer *>(native_);
  const QByteArrayView bytes{transfer.png.unsignedBytes()};
  QByteArray encoded = QByteArray::fromRawData(bytes.data(), bytes.size());
  QBuffer buffer{&encoded};
  if (!buffer.open(QIODevice::ReadOnly)) {
    throw ClipboardImageFailure{ClipboardImageError::read_failed};
  }

  QImageReader reader{&buffer, "PNG"};
  const auto size = reader.size();
  if (!size.isValid() || size.isEmpty()) {
    throw ClipboardImageFailure{ClipboardImageError::invalid_image};
  }

  if (static_cast<std::uint64_t>(size.width()) * static_cast<std::uint64_t>(size.height()) > AttachmentLimits::maximum_pixels) {
    throw ClipboardImageFailure{ClipboardImageError::pixels};
  }

  request.capture.target.validate();
  SensitiveBytes png{memory};
  png.append(transfer.png.view(), AttachmentLimits::maximum_png_bytes);

  return {.request = request, .png = std::move(png), .width = static_cast<std::uint32_t>(size.width()), .height = static_cast<std::uint32_t>(size.height())};
}

}
