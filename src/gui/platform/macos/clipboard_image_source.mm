#include "cf_reference.hpp"
#include "platform/clipboard_image_file.h"
#include "platform/macos/clipboard_image_bridge.h"
#include "tbc/view.hpp"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

using telar::gui::platform::NativeReference;

namespace {

  using NativeSource = NativeReference<CGImageSourceRef>;

  // Bytes a C API hands over as a pointer and a length: the one place the two meet a span.
  template <typename Byte>
  std::span<Byte> cBytes(Byte* data, std::size_t size) noexcept {
#pragma clang unsafe_buffer_usage begin
    return {data, size};
#pragma clang unsafe_buffer_usage end
  }

  void eraseBytes(std::span<std::byte> bytes) noexcept {
    for (std::size_t index = 0; index < bytes.size(); ++index) { // NOLINT(modernize-loop-convert): volatile write must stay indexed
      static_cast<volatile std::byte&>(bytes[index]) = std::byte{};
    }
  }

  class OwnedDescriptor {
  public:
    explicit OwnedDescriptor(int value) noexcept
        : value_(value) {}

    ~OwnedDescriptor() {
      if (value_ >= 0) {
        ::close(value_);
      }
    }

    OwnedDescriptor(const OwnedDescriptor&) = delete;
    OwnedDescriptor& operator=(const OwnedDescriptor&) = delete;
    OwnedDescriptor(OwnedDescriptor&&) = delete;
    OwnedDescriptor& operator=(OwnedDescriptor&&) = delete;

    [[nodiscard]] explicit operator bool() const noexcept {
      return value_ >= 0;
    }

    [[nodiscard]] int get() const noexcept {
      return value_;
    }

  private:
    int value_;
  };

  // The source is a Core Foundation object it retains, depending on no argument.
  tbc::val_static<NativeSource> sourceFromFile(const char* path, std::uint64_t max_source_bytes, std::uint8_t& failure) {
    const OwnedDescriptor descriptor{telarGuiOpenClipboardImageFile(path)};
    if (!descriptor) {
      return NativeSource{nullptr};
    }

    struct stat status{};
    if (::fstat(descriptor.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != ::geteuid() || status.st_size <= 0) {
      return NativeSource{nullptr};
    }

    if (std::cmp_greater(status.st_size, max_source_bytes)) {
      failure = telar_gui_clipboard_source_bytes;
      return NativeSource{nullptr};
    }

    const NativeReference<CFMutableDataRef> data{CFDataCreateMutable(nullptr, status.st_size)};
    if (data.get() == nullptr) {
      failure = telar_gui_clipboard_bad_alloc;
      return NativeSource{nullptr};
    }

    CFDataSetLength(data.get(), status.st_size);
    const auto size = static_cast<std::size_t>(status.st_size);
    auto bytes = cBytes(CFDataGetMutableBytePtr(data.get()), size);
    std::size_t offset = 0;

    while (offset < size) {
      const auto count = ::read(descriptor.get(), bytes.subspan(offset).data(), size - offset);
      if (count < 0 && errno == EINTR) {
        continue;
      }

      if (count <= 0) {
        eraseBytes(std::as_writable_bytes(bytes));
        failure = telar_gui_clipboard_read_failed;
        return NativeSource{nullptr};
      }

      offset += static_cast<std::size_t>(count);
    }

    // ImageIO borrows lazily. Keep an immutable copy before clearing the read.
    const NativeReference<CFDataRef> copy{CFDataCreate(nullptr, bytes.data(), status.st_size)};

    eraseBytes(std::as_writable_bytes(bytes));
    if (copy.get() == nullptr) {
      failure = telar_gui_clipboard_bad_alloc;
      return NativeSource{nullptr};
    }

    NativeSource source{CGImageSourceCreateWithData(copy.get(), nullptr)};
    if (source.get() != nullptr && CGImageSourceGetCount(source.get()) == 0) {
      source.reset();
    }

    return source;
  }

  tbc::val_static<NativeSource> fileSource(NSPasteboard* board, std::uint64_t max_source_bytes, std::uint8_t& failure) {
    constexpr NSUInteger maximum_files = 16;
    const NSArray* const urls = [board readObjectsForClasses:@[ NSURL.class ] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];

    for (NSUInteger index = 0; index < std::min(maximum_files, urls.count); ++index) {
      NSURL* const url = urls[index];
      const char* const path = url.fileSystemRepresentation;
      if (path == nullptr) {
        continue;
      }

      auto source = sourceFromFile(path, max_source_bytes, failure);
      if (source.get() != nullptr || failure == telar_gui_clipboard_bad_alloc) {
        return source;
      }
    }

    return NativeSource{nullptr};
  }

  tbc::val_static<NativeSource> dataSource(NSPasteboard* board, std::uint64_t max_source_bytes, std::uint8_t& failure) {
    for (NSPasteboardType kind in @[ NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg" ]) {
      NSData* const data = [board dataForType:kind];
      if (data == nil || data.length == 0) {
        continue;
      }

      if (data.length > max_source_bytes) {
        failure = telar_gui_clipboard_source_bytes;
        continue;
      }

      failure = telar_gui_clipboard_read_failed;
      NativeSource source{CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr)};
      if (source.get() != nullptr && CGImageSourceGetCount(source.get()) != 0) {
        return source;
      }
    }

    return NativeSource{nullptr};
  }

  std::uint8_t readDimensions(CGImageSourceRef source, std::uint64_t max_pixels, std::uint32_t& out_width, std::uint32_t& out_height) {
    const NativeReference<CFDictionaryRef> properties{CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr)};
    if (properties.get() == nullptr) {
      return telar_gui_clipboard_read_failed;
    }

    const auto* const width_value = static_cast<CFNumberRef>(CFDictionaryGetValue(properties.get(), kCGImagePropertyPixelWidth));
    const auto* const height_value = static_cast<CFNumberRef>(CFDictionaryGetValue(properties.get(), kCGImagePropertyPixelHeight));
    std::int64_t width = 0;
    std::int64_t height = 0;
    if (width_value == nullptr || height_value == nullptr || CFNumberGetValue(width_value, kCFNumberSInt64Type, &width) == 0 || CFNumberGetValue(height_value, kCFNumberSInt64Type, &height) == 0 || width <= 0 || height <= 0) {
      return telar_gui_clipboard_invalid_image;
    }

    if (std::cmp_greater(width, std::numeric_limits<std::uint32_t>::max()) || std::cmp_greater(height, std::numeric_limits<std::uint32_t>::max()) || static_cast<std::uint64_t>(width) > max_pixels / static_cast<std::uint64_t>(height)) {
      return telar_gui_clipboard_pixels;
    }

    out_width = static_cast<std::uint32_t>(width);
    out_height = static_cast<std::uint32_t>(height);
    return telar_gui_clipboard_ok;
  }

  std::uint8_t encodeSource(CGImageSourceRef source, TelarGuiClipboardWriteCallback write_callback, void* write_context) {
    const CGDataConsumerCallbacks callbacks{.putBytes = write_callback, .releaseConsumer = nullptr};
    const NativeReference<CGDataConsumerRef> consumer{CGDataConsumerCreate(write_context, &callbacks)};
    if (consumer.get() == nullptr) {
      return telar_gui_clipboard_bad_alloc;
    }

    const NativeReference<CGImageDestinationRef> destination{CGImageDestinationCreateWithDataConsumer(consumer.get(), CFSTR("public.png"), 1, nullptr)};
    if (destination.get() == nullptr) {
      return telar_gui_clipboard_read_failed;
    }

    CGImageDestinationAddImageFromSource(destination.get(), source, 0, nullptr);
    return CGImageDestinationFinalize(destination.get()) ? telar_gui_clipboard_ok : telar_gui_clipboard_read_failed;
  }

}

void* telarGuiClipboardGeneralPasteboard(int64_t* revision) {
  return telarGuiClipboardRetainPasteboard((__bridge void*)NSPasteboard.generalPasteboard, revision);
}

void* telarGuiClipboardRetainPasteboard(void* pasteboard, int64_t* revision) {
  auto* const board = (__bridge NSPasteboard*)pasteboard;
  if (board == nil) {
    return nullptr;
  }

  if (revision != nullptr) {
    *revision = board.changeCount;
  }

  return (__bridge_retained void*)board;
}

void telarGuiClipboardReleasePasteboard(void* native) {
  if (native != nullptr) {
    CFRelease(native);
  }
}

uint8_t telarGuiClipboardReadPng(
    void* native,
    int64_t revision,
    uint64_t max_source_bytes,
    uint64_t max_pixels,
    TelarGuiClipboardWriteCallback write_callback,
    void* write_context,
    uint32_t* width,
    uint32_t* height
) {
  @autoreleasepool {
    auto* const board = (__bridge NSPasteboard*)native;
    if (board == nil || board.changeCount != revision) {
      return telar_gui_clipboard_changed;
    }

    std::uint8_t failure = telar_gui_clipboard_no_image;
    const auto file_source = fileSource(board, max_source_bytes, failure);

    if (failure == telar_gui_clipboard_bad_alloc) {
      return failure;
    }

    const auto data_source = file_source.get() == nullptr ? dataSource(board, max_source_bytes, failure) : NativeSource{nullptr};
    CGImageSourceRef const active = file_source.get() != nullptr ? file_source.get() : data_source.get();
    if (active == nullptr) {
      return failure;
    }

    if (board.changeCount != revision) {
      return telar_gui_clipboard_changed;
    }

    std::uint32_t pixel_width = 0;
    std::uint32_t pixel_height = 0;
    const auto dim_status = readDimensions(active, max_pixels, pixel_width, pixel_height);
    if (dim_status != telar_gui_clipboard_ok) {
      return dim_status;
    }

    const auto encode_status = encodeSource(active, write_callback, write_context);
    if (encode_status != telar_gui_clipboard_ok) {
      return encode_status;
    }

    if (width != nullptr) {
      *width = pixel_width;
    }

    if (height != nullptr) {
      *height = pixel_height;
    }

    return telar_gui_clipboard_ok;
  }
}
