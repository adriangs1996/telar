#include "attachment_preview.hpp"
#include "application/dependencies.hpp"
#include "attachments/catalog.hpp"
#include "attachments/preview_size.hpp"
#include "attachments/secure_erase.hpp"
#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"
#include "core/memory.hpp"
#include "graphics/artwork_resize.hpp"
#include "memory/allocator.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QBuffer>
#include <QImage>
#include <QImageReader>
#include <QIODevice>
#include <QSize>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <new>
#include <span>
#include <stdexcept>
#include <utility>

namespace telar::gui::qt {

namespace {

struct ImagePixels {
  ApplicationAllocator &memory;
  SensitiveBytes<ApplicationAllocator> bytes;

  static void release(void *context) noexcept {
    auto *const owner = static_cast<ImagePixels *>(context);
    runtime::AllocationDeleter<ImagePixels, ApplicationAllocator>{owner->memory}(owner);
  }
};

class DecodedImage {
public:
  explicit DecodedImage(QImage image) noexcept
      : image_(std::move(image)) {}

  ~DecodedImage() {
    eraseSensitiveBytes(std::as_writable_bytes(std::span{image_.bits(), static_cast<std::size_t>(image_.sizeInBytes())}));
  }

  DecodedImage(const DecodedImage &) = delete;
  DecodedImage &operator=(const DecodedImage &) = delete;
  DecodedImage(DecodedImage &&) = delete;
  DecodedImage &operator=(DecodedImage &&) = delete;

  void makeStraight() {
    if (image_.format() == QImage::Format_RGBA8888) {
      return;
    }

    QImage converted = image_.convertToFormat(QImage::Format_RGBA8888);
    if (converted.isNull()) {
      throw std::bad_alloc{};
    }

    eraseSensitiveBytes(std::as_writable_bytes(std::span{image_.bits(), static_cast<std::size_t>(image_.sizeInBytes())}));
    image_ = std::move(converted);
  }

  [[nodiscard]] const QImage &image() const noexcept {
    return image_;
  }

private:
  QImage image_;
};

QImage resampled(ApplicationAllocator &memory, const QImage &source, AttachmentPreviewSize size) {
  const auto byte_count = static_cast<std::size_t>(size.width) * size.height * RgbaImageView::channels;
  auto pixels = makeOwned<ImagePixels>(memory, ImagePixels{.memory = memory, .bytes = SensitiveBytes{memory}});
  pixels->bytes.resizeZeroed(byte_count, static_cast<std::size_t>(AttachmentPreviewSize::full_pixels) * RgbaImageView::channels);
  const auto view = pixels->bytes.unsignedBytes();
  auto *const rgba = view.data();
  const RgbaImageView input{
      .pixels = std::as_bytes(std::span{source.constBits(), static_cast<std::size_t>(source.sizeInBytes())}),
      .stride = static_cast<std::size_t>(source.bytesPerLine()),
      .width = static_cast<std::size_t>(source.width()),
      .height = static_cast<std::size_t>(source.height()),
  };
  const std::span output{rgba, byte_count};
  if (!ArtworkResize::rectangle(input, output, size.width, size.height)) {
    throw std::invalid_argument{"InvalidClipboardImage"};
  }

  ArtworkResize::premultiply(output);
  const auto *const owner = pixels.get();
  QImage image{rgba, static_cast<int>(size.width), static_cast<int>(size.height), static_cast<qsizetype>(size.width) * static_cast<qsizetype>(RgbaImageView::channels), QImage::Format_RGBA8888_Premultiplied, ImagePixels::release, pixels.get()};
  if (image.isNull()) {
    throw std::bad_alloc{};
  }

  if (pixels.release() != owner) {
    std::terminate();
  }

  return image;
}

}

AttachmentPreview AttachmentPreview::decode(ApplicationAllocator &memory, const AttachmentCapture<ApplicationAllocator> &capture) {
  const QByteArrayView bytes{capture.png.unsignedBytes()};
  QByteArray encoded = QByteArray::fromRawData(bytes.data(), bytes.size());
  QBuffer buffer{&encoded};
  if (!buffer.open(QIODevice::ReadOnly)) {
    throw std::runtime_error{"ClipboardReadFailed"};
  }

  QImageReader reader{&buffer, "PNG"};
  const auto size = reader.size();
  if (!size.isValid() || std::cmp_not_equal(size.width(), capture.width) || std::cmp_not_equal(size.height(), capture.height) || static_cast<std::uint64_t>(capture.width) * capture.height > AttachmentLimits::maximum_pixels) {
    throw std::invalid_argument{"InvalidClipboardImage"};
  }

  DecodedImage decoded{reader.read()};
  if (decoded.image().isNull()) {
    throw std::invalid_argument{"InvalidClipboardImage"};
  }

  decoded.makeStraight();

  return {
      .sequence = capture.request.capture.id,
      .thumbnail = resampled(memory, decoded.image(), AttachmentPreviewSize::fit(capture.width, capture.height, {.side = AttachmentPreviewSize::thumbnail_side, .pixels = AttachmentPreviewSize::thumbnail_side * AttachmentPreviewSize::thumbnail_side})),
      .full = resampled(memory, decoded.image(), AttachmentPreviewSize::fit(capture.width, capture.height, {.side = AttachmentPreviewSize::full_side, .pixels = AttachmentPreviewSize::full_pixels})),
  };
}

}
