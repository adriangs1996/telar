#include "assertions.hpp"
#include "application/dependencies.hpp"
#include "attachments/types.hpp"
#include "platform/clipboard_image_source.hpp"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <QTemporaryDir>
#include <QFile>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <span>
#include <string_view>
#include <stdexcept>
#include <unistd.h>
#include <sys/stat.h>

namespace {

using namespace telar::gui;
using telar::gui::test::require;
using platform::ClipboardImageError;
using platform::ClipboardImageFailure;
using platform::ClipboardImageSource;

constexpr ClipboardCaptureRequest request{.capture = {.id = 1, .target = {.pane_id = 1, .pane_generation = 2}}};
constexpr std::size_t image_width = 2;
constexpr std::size_t image_height = 3;
constexpr std::size_t components = 4;
constexpr std::size_t component_bits = 8;

NSData *_Nonnull imageData(CFStringRef kind) {
  constexpr std::array<std::uint8_t, image_width * image_height * components> pixels{
      255, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 0, 255,
      255, 0, 255, 255, 0, 255, 255, 255,
  };
  auto *const color = CGColorSpaceCreateDeviceRGB();
  auto *const provider = CGDataProviderCreateWithData(nullptr, pixels.data(), pixels.size(), nullptr);
  auto *const image = CGImageCreate(image_width, image_height, component_bits, component_bits * components, image_width * components, color, kCGImageAlphaLast, provider, nullptr, false, kCGRenderingIntentDefault);
  require(image != nullptr, "the fixture image must be valid");
  NSMutableData *const data = [NSMutableData data];
  auto *const destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kind, 1, nullptr);
  require(destination != nullptr, "fixture encoding must be supported");
  CGImageDestinationAddImage(destination, image, nullptr);
  const bool success = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(image);
  CGDataProviderRelease(provider);
  CGColorSpaceRelease(color);
  require(success, "fixture encoding must finish");

  return data;
}

NSString *_Nonnull nativePath(const QString &path) {
  NSString *const value = [NSString stringWithUTF8String:path.toUtf8().constData()];
  if (value == nil) {
    throw std::runtime_error{"InvalidFixturePath"};
  }

  return value;
}

void expectFailure(const ClipboardImageSource &source, ApplicationAllocator &memory, ClipboardImageError expected) {
  try {
    static_cast<void>(source.read(memory, request));
    require(false, "the rejected capture must report its exact reason");
  } catch (const ClipboardImageFailure &error) {
    require(error.code() == expected, "clipboard failures must preserve the named native reason");
  }
}

void encodedFormatsAndRevisionChanges(NSPasteboard *board, ApplicationAllocator &memory) {
  for (NSString *kind in @[NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg"]) {
    [board clearContents];
    require([board setData:imageData((__bridge CFStringRef)kind) forType:kind], "the private board must accept fixture data");
    const auto source = ClipboardImageSource::retainPasteboard((__bridge void *)board);
    const auto captured = source.read(memory, request);
    require(captured.request.capture == request.capture && captured.width == image_width && captured.height == image_height && captured.png.size() != 0, "supported formats must produce an owned PNG with exact capture identity");
    const auto bytes = captured.png.view();
    NSData *const data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    auto *const png = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    require(png != nullptr && CFEqual(CGImageSourceGetType(png), CFSTR("public.png")) != 0, "the worker must normalize each source to PNG");
    CFRelease(png);
    [board clearContents];
    expectFailure(source, memory, ClipboardImageError::changed);
  }
}

void boundedOwnedFilesAndNonregularSources(NSPasteboard *board, ApplicationAllocator &memory) {
  const QTemporaryDir directory;
  require(directory.isValid(), "the owned fixture directory must exist");
  const QString path = directory.filePath(QStringLiteral("image.png"));
  NSData *const png = imageData(CFSTR("public.png"));
  require([png writeToFile:nativePath(path) atomically:YES], "the owned fixture PNG must be written");
  [board clearContents];
  require([board writeObjects:@[[NSURL fileURLWithPath:nativePath(path)]]], "the private board must hold a file URL");
  const auto source = ClipboardImageSource::retainPasteboard((__bridge void *)board);
  const auto captured = source.read(memory, request);
  require(captured.width == image_width && captured.height == image_height, "owned regular files must capture");

  const QString link = directory.filePath(QStringLiteral("symlink.png"));
  require(::symlink(path.toUtf8().constData(), link.toUtf8().constData()) == 0, "the symlink fixture must exist");
  const QString fifo = directory.filePath(QStringLiteral("fifo.png"));
  require(::mkfifo(fifo.toUtf8().constData(), S_IRUSR | S_IWUSR) == 0, "the FIFO fixture must exist");
  for (const auto &rejected : {link, fifo}) {
    [board clearContents];
    require([board writeObjects:@[[NSURL fileURLWithPath:nativePath(rejected)]]], "the private board must accept a rejected URL");
    const auto unsafe = ClipboardImageSource::retainPasteboard((__bridge void *)board);
    expectFailure(unsafe, memory, ClipboardImageError::no_image);
  }

  QFile large{directory.filePath(QStringLiteral("too-large.png"))};
  require(large.open(QIODevice::WriteOnly) && large.resize(static_cast<qint64>(AttachmentLimits::maximum_source_bytes) + 1), "the oversized sparse fixture must exist");
  large.close();
  [board clearContents];
  require([board writeObjects:@[[NSURL fileURLWithPath:nativePath(large.fileName())]]], "the private board must accept an oversized URL");
  const auto oversized = ClipboardImageSource::retainPasteboard((__bridge void *)board);
  expectFailure(oversized, memory, ClipboardImageError::source_bytes);
}

}

int main() {
  @autoreleasepool {
    NSPasteboard *const board = [NSPasteboard pasteboardWithUniqueName];
    int result = 0;
    try {
      ApplicationAllocator memory;
      [board clearContents];
      const auto empty = ClipboardImageSource::retainPasteboard((__bridge void *)board);
      expectFailure(empty, memory, ClipboardImageError::no_image);
      encodedFormatsAndRevisionChanges(board, memory);
      boundedOwnedFilesAndNonregularSources(board, memory);
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      result = 1;
    }

    [board releaseGlobally];

    return result;
  }
}
