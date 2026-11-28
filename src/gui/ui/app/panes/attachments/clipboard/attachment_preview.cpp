module telar.gui.ui.app.panes.attachments.clipboard;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    // Spans over the pixels QImage hands out as raw pointers. This target has no Qt Quick, so it
    // cannot use ui/kit/scene/qt_buffers.hpp.
    std::span<uchar> imageBytes(QImage& image) {
#pragma clang unsafe_buffer_usage begin
      return {image.bits(), static_cast<std::size_t>(image.sizeInBytes())};
#pragma clang unsafe_buffer_usage end
    }

    // constBits() never detaches a shared image, as bits() would.
    std::span<const uchar> constImageBytes(const QImage& image) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {image.constBits(), static_cast<std::size_t>(image.sizeInBytes())};
#pragma clang unsafe_buffer_usage end
    }

    struct ImagePixels {
      ApplicationAllocator& memory;
      SensitiveBytes<ApplicationAllocator> bytes;

      static void release(void* context) noexcept {
        auto* const owner = static_cast<ImagePixels*>(context);

        ds::Box<ImagePixels, ApplicationAllocator>::fromRaw(owner, owner->memory).reset();
      }
    };

    class DecodedImage {
    public:
      explicit DecodedImage(QImage image) noexcept
          : image_(std::move(image)) {}

      ~DecodedImage() {
        eraseSensitiveBytes(std::as_writable_bytes(imageBytes(image_)));
      }

      DecodedImage(const DecodedImage&) = delete;
      DecodedImage& operator=(const DecodedImage&) = delete;
      DecodedImage(DecodedImage&&) = delete;
      DecodedImage& operator=(DecodedImage&&) = delete;

      void makeStraight() {
        if (image_.format() == QImage::Format_RGBA8888) {
          return;
        }

        QImage converted = image_.convertToFormat(QImage::Format_RGBA8888);
        if (converted.isNull()) {
          throw std::bad_alloc{};
        }

        eraseSensitiveBytes(std::as_writable_bytes(imageBytes(image_)));
        image_ = std::move(converted);
      }

      [[nodiscard]] const QImage& image() const noexcept {
        return image_;
      }

    private:
      QImage image_;
    };

    QImage resampled(ApplicationAllocator& memory, const QImage& source, application::terminal::attachments::AttachmentPreviewSize size) {
      const auto byte_count = static_cast<std::size_t>(size.width) * size.height * application::terminal::graphics::RgbaImageView::channels;
      auto pixels = ds::makeBox<ImagePixels>(memory, ImagePixels{.memory = memory, .bytes = SensitiveBytes<ApplicationAllocator>{memory}});

      pixels.getMut().bytes.resizeZeroed(byte_count, static_cast<std::size_t>(application::terminal::attachments::AttachmentPreviewSize::full_pixels) * application::terminal::graphics::RgbaImageView::channels);
      const auto view = pixels.getMut().bytes.unsignedBytesMut();
      auto* const rgba = view.data();
      const application::terminal::graphics::RgbaImageView input{
          .pixels = std::as_bytes(constImageBytes(source)),
          .stride = static_cast<std::size_t>(source.bytesPerLine()),
          .width = static_cast<std::size_t>(source.width()),
          .height = static_cast<std::size_t>(source.height()),
      };

      const auto output = view.first(byte_count);
      if (!application::terminal::graphics::ArtworkResize::rectangle(input, output, size.width, size.height)) {
        throw std::invalid_argument{"InvalidClipboardImage"};
      }

      application::terminal::graphics::ArtworkResize::premultiply(output);
      const auto* const owner = &pixels.get();
      QImage image{rgba, static_cast<int>(size.width), static_cast<int>(size.height), static_cast<qsizetype>(size.width) * static_cast<qsizetype>(application::terminal::graphics::RgbaImageView::channels), QImage::Format_RGBA8888_Premultiplied, ImagePixels::release, &pixels.getMut()};
      if (image.isNull()) {
        throw std::bad_alloc{};
      }

      if (pixels.intoRaw() != owner) {
        std::terminate();
      }

      return image;
    }

  }

  AttachmentPreview AttachmentPreview::decode(ApplicationAllocator& memory, const AttachmentCapture<ApplicationAllocator>& capture) {
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
        .thumbnail = resampled(memory, decoded.image(), application::terminal::attachments::AttachmentPreviewSize::fit(capture.width, capture.height, {.side = application::terminal::attachments::AttachmentPreviewSize::thumbnail_side, .pixels = application::terminal::attachments::AttachmentPreviewSize::thumbnail_side * application::terminal::attachments::AttachmentPreviewSize::thumbnail_side})),
        .full = resampled(memory, decoded.image(), application::terminal::attachments::AttachmentPreviewSize::fit(capture.width, capture.height, {.side = application::terminal::attachments::AttachmentPreviewSize::full_side, .pixels = application::terminal::attachments::AttachmentPreviewSize::full_pixels})),
    };
  }

}
