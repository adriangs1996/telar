#include "platform/private_clipboard.hpp"
#include "telar_clipboard/clipboard.hpp"
#import <AppKit/AppKit.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <print>
#include <random>
#include <string>
#include <unistd.h>
#include <vector>

// Defined in cli.cpp, which this test links in place of the reader's main.
namespace telar::clipboard {
  int runCli(int argc, char** argv);
}

namespace {
  void check(bool condition, const char* message) {
    if (!condition) {
      std::println(stderr, "FAIL: {}", message);
      std::exit(1);
    }
  }

  void checkFile(const telar::clipboard::Content& expected) {
    std::string path = (std::filesystem::temp_directory_path() / "clipboard-test-XXXXXX").string();
    const int descriptor = mkstemp(path.data());

    check(descriptor >= 0, "create isolated output file");
    close(descriptor);

    auto program = std::to_array("clipboard");
    auto option = std::to_array("--output");
    std::array arguments{program.data(), option.data(), path.data()};

    check(telar::clipboard::runCli(static_cast<int>(arguments.size()), arguments.data()) == 0, "CLI saves content");

    FILE* file = std::fopen(path.c_str(), "rb");

    check(file != nullptr, "open saved content");
    const auto size = expected.bytes.size();
    std::vector<telar::clipboard::byte> actual(size);

    check(size == 0 || std::fread(actual.data(), 1, size, file) == size, "read saved bytes");
    check(std::fgetc(file) == EOF && std::ferror(file) == 0, "no extra output bytes");
    check(actual == expected.bytes, "CLI output is byte-exact");
    std::fclose(file);
    std::filesystem::remove(path);
  }
}

namespace {
  void run() {
    @autoreleasepool {
      telar::gui::test::PrivateClipboard isolated;
      NSPasteboard* board = [NSPasteboard generalPasteboard];

      isolated.clear();
      auto result = telar::clipboard::read();

      check(!result && result.error() == telar::clipboard::ReadError::no_supported_content, "empty clipboard");
      auto program = std::to_array("clipboard");
      std::array arguments{program.data()};

      check(telar::clipboard::runCli(static_cast<int>(arguments.size()), arguments.data()) == 1, "CLI reports missing content");

      NSMutableString* text = [NSMutableString stringWithString:@"UTF-8: áéíóú 🧵\n"];

      [text appendString:[@"" stringByPaddingToLength:NSUInteger{128} * 1024 withString:@"x" startingAtIndex:0]];
      check([board setString:text forType:NSPasteboardTypeString], "set large UTF-8 text");
      NSData* text_data = [text dataUsingEncoding:NSUTF8StringEncoding];

      result = telar::clipboard::read();
      check(result.has_value(), "read text larger than 2048 bytes");
      check(result->mime_type == "text/plain;charset=utf-8", "text MIME type");
      check(result->bytes.size() == text_data.length && std::memcmp(result->bytes.data(), text_data.bytes, text_data.length) == 0, "UTF-8 bytes preserved");
      checkFile(*result);
      const auto limited_text = telar::clipboard::read(text_data.length - 1);

      check(!limited_text && limited_text.error() == telar::clipboard::ReadError::content_too_large, "text byte limit enforced");
      check(telar::clipboard::read(text_data.length).has_value(), "text at exact byte limit accepted");

      isolated.clear();
      check([board setString:@"" forType:NSPasteboardTypeString], "set empty text");
      result = telar::clipboard::read();
      check(result && result->bytes.empty(), "empty text remains valid");
      checkFile(*result);

      NSBitmapImageRep* image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:128 pixelsHigh:128 bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];

      check(image != nil && image.bitmapData != nullptr, "create test image");
      std::mt19937 random(0); // NOLINT(bugprone-random-generator-seed,cert-msc32-c,cert-msc51-cpp): a fixed seed keeps a failing image reproducible.

      for (NSInteger index = 0; index < image.bytesPerRow * image.pixelsHigh; ++index) {
        image.bitmapData[index] = static_cast<unsigned char>(random());
      }

      struct image_format {
        NSPasteboardType type;
        NSBitmapImageFileType encoding;
        std::string_view mime_type;
      };

      const std::array formats{
          image_format{.type = NSPasteboardTypePNG, .encoding = NSBitmapImageFileTypePNG, .mime_type = "image/png"},
          image_format{.type = NSPasteboardTypeTIFF, .encoding = NSBitmapImageFileTypeTIFF, .mime_type = "image/tiff"},
          image_format{.type = @"public.jpeg", .encoding = NSBitmapImageFileTypeJPEG, .mime_type = "image/jpeg"},
      };

      for (const auto& format : formats) {
        NSData* data = [image representationUsingType:format.encoding properties:@{}];

        check(data != nil && data.length > 2048, "encode image larger than old buffer");
        isolated.clear();
        check([board setData:data forType:format.type], "set image");
        check([board setString:@"alternate text" forType:NSPasteboardTypeString], "set alternate text representation");
        result = telar::clipboard::read();
        check(result.has_value(), "read encoded image");
        if (result->mime_type != format.mime_type) {
          std::println(stderr, "Expected {}, got {}; advertised types: {}", format.mime_type, result->mime_type, board.types.description.UTF8String);
        }

        check(result->mime_type == format.mime_type, "image preferred over text with correct MIME type");
        check(result->bytes.size() == data.length && std::memcmp(result->bytes.data(), data.bytes, data.length) == 0, "encoded image preserved without conversion");
        checkFile(*result);
        const auto limited_image = telar::clipboard::read(data.length - 1);

        check(!limited_image && limited_image.error() == telar::clipboard::ReadError::content_too_large, "image byte limit enforced");
        check(telar::clipboard::read(data.length).has_value(), "image at exact byte limit accepted");
      }

      isolated.clear();
      check([board setData:[NSData dataWithBytes:"unsupported" length:11] forType:@"org.telar.unsupported"], "set unsupported content");
      result = telar::clipboard::read();
      check(!result && result.error() == telar::clipboard::ReadError::no_supported_content, "unsupported content rejected");

      std::puts("Passed: large UTF-8 text, empty text, PNG, TIFF, JPEG, MIME types, image priority, exact CLI files and unsupported content. System clipboard unchanged.");
    }
  }
}

int main() {
  try {
    run();
  } catch (...) {
    std::fputs("FAIL: unexpected exception\n", stderr);
    return 1;
  }

  return 0;
}
