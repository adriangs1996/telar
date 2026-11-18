#include "features/terminal/attachments/types.hpp"
#include "foundation/core/application_memory.hpp"
#include "objc_case.hpp"
#include "platform/clipboard_image_source.hpp"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <QFile>
#include <QTemporaryDir>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace {

  using namespace telar::gui;
  using platform::ClipboardImageError;
  using platform::ClipboardImageFailure;
  using platform::ClipboardImageSource;
  using telar::gui::test::check;

  constexpr ClipboardCaptureRequest request{.capture = {.id = 1, .target = {.pane_id = 1, .pane_generation = 2}}};
  constexpr std::size_t image_width = 2;
  constexpr std::size_t image_height = 3;
  constexpr std::size_t components = 4;
  constexpr std::size_t component_bits = 8;

  NSData* _Nonnull imageData(CFStringRef kind) {
    constexpr std::array<std::uint8_t, image_width * image_height * components> pixels{
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        255,
        255,
        255,
        0,
        255,
        255,
        0,
        255,
        255,
        0,
        255,
        255,
        255,
    };

    auto* const color = CGColorSpaceCreateDeviceRGB();
    auto* const provider = CGDataProviderCreateWithData(nullptr, pixels.data(), pixels.size(), nullptr);
    auto* const image = CGImageCreate(image_width, image_height, component_bits, component_bits * components, image_width * components, color, kCGImageAlphaLast, provider, nullptr, false, kCGRenderingIntentDefault);

    check(image != nullptr, "the fixture image must be valid");
    NSMutableData* const data = [NSMutableData data];
    auto* const destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kind, 1, nullptr);

    check(destination != nullptr, "fixture encoding must be supported");
    CGImageDestinationAddImage(destination, image, nullptr);
    const bool success = CGImageDestinationFinalize(destination);

    CFRelease(destination);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color);
    check(success, "fixture encoding must finish");

    return data;
  }

  NSString* _Nonnull nativePath(const QString& path) {
    NSString* const value = [NSString stringWithUTF8String:path.toUtf8().constData()];
    if (value == nil) {
      throw std::runtime_error{"InvalidFixturePath"};
    }

    return value;
  }

  void expectFailure(const ClipboardImageSource& source, ApplicationAllocator& memory, ClipboardImageError expected) {
    try {
      static_cast<void>(source.read(memory, request));
      check(false, "the rejected capture must report its exact reason");
    } catch (const ClipboardImageFailure& error) {
      check(error.code() == expected, "clipboard failures must preserve the named native reason");
    }
  }

  void encodedFormatsAndRevisionChanges(NSPasteboard* board, ApplicationAllocator& memory) {
    for (NSString* kind in @[ NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg" ]) {
      [board clearContents];
      check([board setData:imageData((__bridge CFStringRef)kind) forType:kind], "the private board must accept fixture data");
      const auto source = ClipboardImageSource::retainPasteboard((__bridge void*)board);
      const auto captured = source.read(memory, request);

      check(captured.request.capture == request.capture && captured.width == image_width && captured.height == image_height && captured.png.size() != 0, "supported formats must produce an owned PNG with exact capture identity");
      const auto bytes = captured.png.view();
      NSData* const data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
      auto* const png = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);

      check(png != nullptr && CFEqual(CGImageSourceGetType(png), CFSTR("public.png")) != 0, "the worker must normalize each source to PNG");
      CFRelease(png);
      [board clearContents];
      expectFailure(source, memory, ClipboardImageError::changed);
    }
  }

  void boundedOwnedFilesAndNonregularSources(NSPasteboard* board, ApplicationAllocator& memory) {
    const QTemporaryDir directory;

    check(directory.isValid(), "the owned fixture directory must exist");
    const QString path = directory.filePath(QStringLiteral("image.png"));
    NSData* const png = imageData(CFSTR("public.png"));

    check([png writeToFile:nativePath(path) atomically:YES], "the owned fixture PNG must be written");
    [board clearContents];
    check([board writeObjects:@[ [NSURL fileURLWithPath:nativePath(path)] ]], "the private board must hold a file URL");
    const auto source = ClipboardImageSource::retainPasteboard((__bridge void*)board);
    const auto captured = source.read(memory, request);

    check(captured.width == image_width && captured.height == image_height, "owned regular files must capture");

    const QString link = directory.filePath(QStringLiteral("symlink.png"));

    check(::symlink(path.toUtf8().constData(), link.toUtf8().constData()) == 0, "the symlink fixture must exist");
    const QString fifo = directory.filePath(QStringLiteral("fifo.png"));

    check(::mkfifo(fifo.toUtf8().constData(), S_IRUSR | S_IWUSR) == 0, "the FIFO fixture must exist");
    for (const auto& rejected : {link, fifo}) {
      [board clearContents];
      check([board writeObjects:@[ [NSURL fileURLWithPath:nativePath(rejected)] ]], "the private board must accept a rejected URL");
      const auto unsafe = ClipboardImageSource::retainPasteboard((__bridge void*)board);

      expectFailure(unsafe, memory, ClipboardImageError::no_image);
    }

    QFile large{directory.filePath(QStringLiteral("too-large.png"))};

    check(large.open(QIODevice::WriteOnly) && large.resize(static_cast<qint64>(AttachmentLimits::maximum_source_bytes) + 1), "the oversized sparse fixture must exist");
    large.close();
    [board clearContents];
    check([board writeObjects:@[ [NSURL fileURLWithPath:nativePath(large.fileName())] ]], "the private board must accept an oversized URL");
    const auto oversized = ClipboardImageSource::retainPasteboard((__bridge void*)board);

    expectFailure(oversized, memory, ClipboardImageError::source_bytes);
  }

  void emptyBoard(NSPasteboard* board, ApplicationAllocator& memory) {
    [board clearContents];
    const auto empty = ClipboardImageSource::retainPasteboard((__bridge void*)board);

    expectFailure(empty, memory, ClipboardImageError::no_image);
  }

  // A private pasteboard and the application's memory for one case.
  template <void (*verify)(NSPasteboard*, ApplicationAllocator&)>
  void onPrivateBoard() {
    @autoreleasepool {
      NSPasteboard* const board = [NSPasteboard pasteboardWithUniqueName];

      {
        ApplicationMemory application_memory;

        verify(board, application_memory.memory());
      }

      [board releaseGlobally];
    }
  }

  const telar::gui::test::ObjcCase case_empty_board{"clipboard_image_source.empty_board", onPrivateBoard<emptyBoard>};
  const telar::gui::test::ObjcCase case_encoded_formats_and_revision_changes{"clipboard_image_source.encoded_formats_and_revision_changes", onPrivateBoard<encodedFormatsAndRevisionChanges>};
  const telar::gui::test::ObjcCase case_bounded_owned_files_and_nonregular_sources{"clipboard_image_source.bounded_owned_files_and_nonregular_sources", onPrivateBoard<boundedOwnedFilesAndNonregularSources>};

}
