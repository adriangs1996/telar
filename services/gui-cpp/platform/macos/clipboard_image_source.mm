#include "tbc/view.hpp"
#include "platform/clipboard_image_source.hpp"
#include "application/dependencies.hpp"
#include "attachments/capture.hpp"
#include "attachments/secure_erase.hpp"
#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"
#include "platform/clipboard_image_file.h"
#include "platform/clipboard_image_monitor.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <limits>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace telar::gui::platform {

namespace {

template <typename Value>
class NativeReference {
public:
  explicit NativeReference(Value value) noexcept
      : value_(value) {}

  ~NativeReference() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }

  NativeReference(const NativeReference &) = delete;
  NativeReference &operator=(const NativeReference &) = delete;
  NativeReference(NativeReference &&other) noexcept
      : value_(std::exchange(other.value_, nullptr)) {}
  NativeReference &operator=(NativeReference &&) = delete;

  [[nodiscard]] Value get() const noexcept {
    return value_;
  }

private:
  Value value_;
};

using NativeSource = NativeReference<CGImageSourceRef>;

// The source is a Core Foundation object it retains, depending on no argument.
tbc::view<NativeSource, tbc::lt::static_storage> sourceFromFile(const char *path, ClipboardImageError &failure) {
  const runtime::FileDescriptor descriptor{telarGuiOpenClipboardImageFile(path)};
  if (!descriptor) {
    return NativeSource{nullptr};
  }

  struct stat status{};
  if (::fstat(descriptor.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != ::geteuid() || status.st_size <= 0) {
    return NativeSource{nullptr};
  }

  if (std::cmp_greater(status.st_size, AttachmentLimits::maximum_source_bytes)) {
    failure = ClipboardImageError::source_bytes;

    return NativeSource{nullptr};
  }

  const NativeReference data{CFDataCreateMutable(nullptr, status.st_size)};
  if (data.get() == nullptr) {
    throw std::bad_alloc{};
  }

  CFDataSetLength(data.get(), status.st_size);
  auto *const bytes = CFDataGetMutableBytePtr(data.get());
  std::size_t offset = 0;
  const auto size = static_cast<std::size_t>(status.st_size);
  while (offset < size) {
    const auto count = ::read(descriptor.get(), bytes + offset, size - offset);
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count <= 0) {
      eraseSensitiveBytes(std::as_writable_bytes(std::span{bytes, size}));
      failure = ClipboardImageError::read_failed;

      return NativeSource{nullptr};
    }

    offset += static_cast<std::size_t>(count);
  }

  // ImageIO borrows lazily. Keep an immutable copy before clearing the read.
  const NativeReference copy{CFDataCreate(nullptr, bytes, status.st_size)};
  eraseSensitiveBytes(std::as_writable_bytes(std::span{bytes, size}));
  if (copy.get() == nullptr) {
    throw std::bad_alloc{};
  }

  NativeSource source{CGImageSourceCreateWithData(copy.get(), nullptr)};
  if (source.get() == nullptr || CGImageSourceGetCount(source.get()) == 0) {
    return NativeSource{nullptr};
  }

  return source;
}

NativeSource fileSource(NSPasteboard *board, ClipboardImageError &failure) {
  constexpr NSUInteger maximum_files = 16;
  const NSArray *const urls = [board readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
  for (NSUInteger index = 0; index < std::min(maximum_files, urls.count); ++index) {
    NSURL *const url = urls[index];
    const char *const path = url.fileSystemRepresentation;
    if (path == nullptr) {
      continue;
    }

    auto source = sourceFromFile(path, failure);
    if (source.get() != nullptr) {
      return source;
    }
  }

  return NativeSource{nullptr};
}

NativeSource dataSource(NSPasteboard *board, ClipboardImageError &failure) {
  for (NSPasteboardType kind in @[NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg"]) {
    NSData *const data = [board dataForType:kind];
    if (data == nil || data.length == 0) {
      continue;
    }

    if (data.length > AttachmentLimits::maximum_source_bytes) {
      failure = ClipboardImageError::source_bytes;

      continue;
    }

    failure = ClipboardImageError::read_failed;
    NativeSource source{CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr)};
    if (source.get() != nullptr && CGImageSourceGetCount(source.get()) != 0) {
      return source;
    }
  }

  return NativeSource{nullptr};
}

struct ImageDimensions {
  std::uint32_t width;
  std::uint32_t height;
};

ImageDimensions dimensions(CGImageSourceRef source) {
  const NativeReference properties{CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr)};
  if (properties.get() == nullptr) {
    throw ClipboardImageFailure{ClipboardImageError::read_failed};
  }

  const auto *const width_value = static_cast<CFNumberRef>(CFDictionaryGetValue(properties.get(), kCGImagePropertyPixelWidth));
  const auto *const height_value = static_cast<CFNumberRef>(CFDictionaryGetValue(properties.get(), kCGImagePropertyPixelHeight));
  std::int64_t width = 0;
  std::int64_t height = 0;
  if (width_value == nullptr || height_value == nullptr || CFNumberGetValue(width_value, kCFNumberSInt64Type, &width) == 0 || CFNumberGetValue(height_value, kCFNumberSInt64Type, &height) == 0 || width <= 0 || height <= 0) {
    throw ClipboardImageFailure{ClipboardImageError::invalid_image};
  }

  if (std::cmp_greater(width, std::numeric_limits<std::uint32_t>::max()) || std::cmp_greater(height, std::numeric_limits<std::uint32_t>::max()) || static_cast<std::uint64_t>(width) > AttachmentLimits::maximum_pixels / static_cast<std::uint64_t>(height)) {
    throw ClipboardImageFailure{ClipboardImageError::pixels};
  }

  return {.width = static_cast<std::uint32_t>(width), .height = static_cast<std::uint32_t>(height)};
}

struct PngWriter {
  SensitiveBytes<ApplicationAllocator> bytes;
  std::exception_ptr failure;

  static std::size_t write(void *writer_context, const void *writer_bytes, std::size_t size) noexcept {
    return append(*static_cast<PngWriter *>(writer_context), {static_cast<const std::byte *>(writer_bytes), size});
  }

  static std::size_t append(PngWriter &writer, std::span<const std::byte> bytes) noexcept {
    if (writer.failure != nullptr) {
      return 0;
    }

    try {
      writer.bytes.append(bytes, AttachmentLimits::maximum_png_bytes);
    } catch (...) {
      writer.failure = std::current_exception();

      return 0;
    }

    return bytes.size();
  }
};

// The bytes are allocated from memory, region `a`.
tbc::view<SensitiveBytes<ApplicationAllocator>, tbc::lt::a> encode(tbc::view<ApplicationAllocator &, tbc::lt::a> memory, CGImageSourceRef source) {
  PngWriter writer{.bytes = SensitiveBytes{memory}, .failure = nullptr};
  const CGDataConsumerCallbacks callbacks{.putBytes = PngWriter::write, .releaseConsumer = nullptr};
  const NativeReference consumer{CGDataConsumerCreate(&writer, &callbacks)};
  if (consumer.get() == nullptr) {
    throw std::bad_alloc{};
  }

  const NativeReference destination{CGImageDestinationCreateWithDataConsumer(consumer.get(), CFSTR("public.png"), 1, nullptr)};
  if (destination.get() == nullptr) {
    throw ClipboardImageFailure{ClipboardImageError::read_failed};
  }

  CGImageDestinationAddImageFromSource(destination.get(), source, 0, nullptr);
  const bool success = CGImageDestinationFinalize(destination.get());
  if (writer.failure != nullptr) {
    try {
      std::rethrow_exception(writer.failure);
    } catch (const std::length_error &) {
      throw ClipboardImageFailure{ClipboardImageError::png_bytes};
    }
  }

  if (!success || writer.bytes.size() == 0) {
    throw ClipboardImageFailure{ClipboardImageError::read_failed};
  }

  return std::move(writer.bytes);
}

}

ClipboardImageSource::ClipboardImageSource(void *native, std::int64_t revision) noexcept
    : native_(native),
      revision_(revision) {}

ClipboardImageSource ClipboardImageSource::snapshot([[maybe_unused]] ApplicationAllocator &memory) {
  return retainPasteboard((__bridge void *)NSPasteboard.generalPasteboard);
}

ClipboardImageSource ClipboardImageSource::retainPasteboard(void *pasteboard) {
  auto *const board = (__bridge NSPasteboard *)pasteboard;
  if (board == nil) {
    throw ClipboardImageFailure{ClipboardImageError::no_image};
  }

  return ClipboardImageSource{(__bridge_retained void *)board, board.changeCount};
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
    CFRelease(native_);
    native_ = nullptr;
  }
}

AttachmentCapture<ApplicationAllocator> ClipboardImageSource::read(ApplicationAllocator &memory, ClipboardCaptureRequest request) const {
  @autoreleasepool {
    auto *const board = (__bridge NSPasteboard *)native_;
    if (board == nil || board.changeCount != revision_) {
      throw ClipboardImageFailure{ClipboardImageError::changed};
    }

    ClipboardImageError failure = ClipboardImageError::no_image;
    const auto source = fileSource(board, failure);
    if (source.get() == nullptr) {
      const auto data = dataSource(board, failure);
      if (data.get() == nullptr) {
        throw ClipboardImageFailure{failure};
      }

      if (board.changeCount != revision_) {
        throw ClipboardImageFailure{ClipboardImageError::changed};
      }

      const auto size = dimensions(data.get());
      request.capture.target.validate();

      return {.request = request, .png = encode(memory, data.get()), .width = size.width, .height = size.height};
    }

    if (board.changeCount != revision_) {
      throw ClipboardImageFailure{ClipboardImageError::changed};
    }

    const auto size = dimensions(source.get());
    request.capture.target.validate();

    return {.request = request, .png = encode(memory, source.get()), .width = size.width, .height = size.height};
  }
}

struct ClipboardImageMonitor::Native {};

ClipboardImageMonitor::ClipboardImageMonitor(ApplicationAllocator &memory)
    : memory_(memory),
      native_(nullptr, AllocationDeleter<Native, ApplicationAllocator>{memory}) {}

ClipboardImageMonitor::~ClipboardImageMonitor() = default;

void ClipboardImageMonitor::cancel() noexcept {}

ClipboardImageSource ClipboardImageMonitor::snapshot() {
  return ClipboardImageSource::snapshot(memory_);
}

}
