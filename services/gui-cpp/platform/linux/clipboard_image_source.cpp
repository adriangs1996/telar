#include "platform/clipboard_image_source.hpp"
#include "platform/clipboard_image_pipe.hpp"
#include "platform/clipboard_image_transfer.hpp"
#include "platform/file_descriptor.hpp"
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
#include <QtCore/qstringliteral.h>
#include <cstddef>
#include <cstdint>
#include <span>
#include <memory>
#include <optional>
#include <utility>

namespace telar::gui::platform {

namespace {

struct Transfer {
  ApplicationAllocator &memory;
  SensitiveBytes<ApplicationAllocator> png;
  runtime::FileDescriptor pipe;
  std::shared_ptr<ClipboardImageTransfer> status;
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

  auto transfer = makeOwned<Transfer>(memory, Transfer{.memory = memory, .png = SensitiveBytes{memory}, .pipe = runtime::FileDescriptor{}, .status = {}});

  QByteArray encoded = mime->data(QStringLiteral("image/png"));
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

ClipboardImageSource ClipboardImageSource::fromPipe(ApplicationAllocator &memory, runtime::FileDescriptor descriptor, std::shared_ptr<ClipboardImageTransfer> status) {
  auto transfer = makeOwned<Transfer>(memory, Transfer{.memory = memory, .png = SensitiveBytes{memory}, .pipe = std::move(descriptor), .status = std::move(status)});

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
  SensitiveBytes png{memory};
  if (transfer.pipe) {
    try {
      png = ClipboardImagePipe::read(memory, transfer.pipe.get());
    } catch (const ClipboardImageFailure &error) {
      const auto failure = transfer.status ? transfer.status->failure() : std::nullopt;
      if (failure && (error.code() == ClipboardImageError::read_failed || error.code() == ClipboardImageError::no_image)) {
        throw ClipboardImageFailure{*failure};
      }

      throw;
    }

    if (const auto failure = transfer.status ? transfer.status->failure() : std::nullopt) {
      throw ClipboardImageFailure{*failure};
    }
  } else {
    png.append(transfer.png.view(), AttachmentLimits::maximum_png_bytes);
  }

  const QByteArrayView bytes{png.unsignedBytes()};
  QByteArray encoded = QByteArray::fromRawData(bytes.data(), bytes.size());
  QBuffer buffer{&encoded};
  if (!buffer.open(QIODevice::ReadOnly)) {
    throw ClipboardImageFailure{ClipboardImageError::read_failed};
  }

  const QImageReader reader{&buffer, "PNG"};
  const auto size = reader.size();
  if (!size.isValid() || size.isEmpty()) {
    throw ClipboardImageFailure{ClipboardImageError::invalid_image};
  }

  if (static_cast<std::uint64_t>(size.width()) * static_cast<std::uint64_t>(size.height()) > AttachmentLimits::maximum_pixels) {
    throw ClipboardImageFailure{ClipboardImageError::pixels};
  }

  request.capture.target.validate();

  return {.request = request, .png = std::move(png), .width = static_cast<std::uint32_t>(size.width()), .height = static_cast<std::uint32_t>(size.height())};
}

}
