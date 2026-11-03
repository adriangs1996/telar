#define main clipboard_cli_main
#include "../main.cpp"
#undef main

#include "platform/private_clipboard.hpp"
#import <AppKit/AppKit.h>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <random>
#include <string>

namespace {
  void check(bool condition, const char *message) {
    if (!condition) {
      std::fprintf(stderr, "FAIL: %s\n", message);
      std::exit(1);
    }
  }

  void checkFile(const telar::clipboard::content &expected) {
    std::string path = (std::filesystem::temp_directory_path() / "clipboard-test-XXXXXX").string();
    const int descriptor = mkstemp(path.data());
    check(descriptor >= 0, "create isolated output file");
    close(descriptor);

    char program[] = "clipboard";
    char option[] = "--output";
    char *arguments[] = {program, option, path.data()};
    check(clipboard_cli_main(3, arguments) == 0, "CLI saves content");

    FILE *file = std::fopen(path.c_str(), "rb");
    check(file != nullptr, "open saved content");
    std::vector<telar::clipboard::byte> actual(expected.bytes.size());
    check(actual.empty() || std::fread(actual.data(), 1, actual.size(), file) == actual.size(), "read saved bytes");
    check(std::fgetc(file) == EOF && std::ferror(file) == 0, "no extra output bytes");
    check(actual == expected.bytes, "CLI output is byte-exact");
    std::fclose(file);
    std::filesystem::remove(path);
  }
}

int main() {
  @autoreleasepool {
    telar::gui::test::PrivateClipboard isolated;
    NSPasteboard *board = [NSPasteboard generalPasteboard];

    isolated.clear();
    auto result = telar::clipboard::read();
    check(!result && result.error() == telar::clipboard::read_error::no_supported_content, "empty clipboard");
    char program[] = "clipboard";
    char *arguments[] = {program};
    check(clipboard_cli_main(1, arguments) == 1, "CLI reports missing content");

    NSMutableString *text = [NSMutableString stringWithString:@"UTF-8: áéíóú 🧵\n"];
    [text appendString:[@"" stringByPaddingToLength:128 * 1024 withString:@"x" startingAtIndex:0]];
    check([board setString:text forType:NSPasteboardTypeString], "set large UTF-8 text");
    NSData *text_data = [text dataUsingEncoding:NSUTF8StringEncoding];
    result = telar::clipboard::read();
    check(result.has_value(), "read text larger than 2048 bytes");
    check(result->mime_type == "text/plain;charset=utf-8", "text MIME type");
    check(result->bytes.size() == text_data.length && std::memcmp(result->bytes.data(), text_data.bytes, text_data.length) == 0, "UTF-8 bytes preserved");
    checkFile(*result);

    isolated.clear();
    check([board setString:@"" forType:NSPasteboardTypeString], "set empty text");
    result = telar::clipboard::read();
    check(result && result->bytes.empty(), "empty text remains valid");
    checkFile(*result);

    NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:128 pixelsHigh:128 bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    check(image != nil && image.bitmapData != nullptr, "create test image");
    std::mt19937 random(0);
    for (NSInteger index = 0; index < image.bytesPerRow * image.pixelsHigh; ++index) {
      image.bitmapData[index] = static_cast<unsigned char>(random());
    }

    struct image_format {
      NSPasteboardType type;
      NSBitmapImageFileType encoding;
      std::string_view mime_type;
    };

    const image_format formats[] = {
        {NSPasteboardTypePNG, NSBitmapImageFileTypePNG, "image/png"},
        {NSPasteboardTypeTIFF, NSBitmapImageFileTypeTIFF, "image/tiff"},
        {@"public.jpeg", NSBitmapImageFileTypeJPEG, "image/jpeg"},
    };

    for (const auto &format : formats) {
      NSData *data = [image representationUsingType:format.encoding properties:@{}];
      check(data != nil && data.length > 2048, "encode image larger than old buffer");
      isolated.clear();
      check([board setData:data forType:format.type], "set image");
      check([board setString:@"alternate text" forType:NSPasteboardTypeString], "set alternate text representation");
      result = telar::clipboard::read();
      check(result.has_value(), "read encoded image");
      if (result->mime_type != format.mime_type) {
        std::fprintf(stderr, "Expected %.*s, got %.*s; advertised types: %s\n", static_cast<int>(format.mime_type.size()), format.mime_type.data(), static_cast<int>(result->mime_type.size()), result->mime_type.data(), board.types.description.UTF8String);
      }

      check(result->mime_type == format.mime_type, "image preferred over text with correct MIME type");
      check(result->bytes.size() == data.length && std::memcmp(result->bytes.data(), data.bytes, data.length) == 0, "encoded image preserved without conversion");
      checkFile(*result);
    }

    isolated.clear();
    check([board setData:[NSData dataWithBytes:"unsupported" length:11] forType:@"org.telar.unsupported"], "set unsupported content");
    result = telar::clipboard::read();
    check(!result && result.error() == telar::clipboard::read_error::no_supported_content, "unsupported content rejected");

    std::puts("Passed: large UTF-8 text, empty text, PNG, TIFF, JPEG, MIME types, image priority, exact CLI files and unsupported content. System clipboard unchanged.");
  }
}
