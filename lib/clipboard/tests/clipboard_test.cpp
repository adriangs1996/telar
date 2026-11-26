#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "macos_pasteboard_fixture.h"
#include "platform/private_clipboard.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

import telar.clipboard;

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

  void captureBytes(void* context, const unsigned char* bytes, std::size_t size) {
    auto& out = *static_cast<std::vector<telar::clipboard::byte>*>(context);
#pragma clang unsafe_buffer_usage begin
    const std::span<const unsigned char> slice{bytes, size};
#pragma clang unsafe_buffer_usage end

    out.assign(slice.begin(), slice.end());
  }

  void run() {
    telar::gui::test::PrivateClipboard isolated;

    isolated.clear();
    auto result = telar::clipboard::read();

    check(!result && result.error() == telar::clipboard::ReadError::no_supported_content, "empty clipboard");
    auto program = std::to_array("clipboard");
    std::array arguments{program.data()};

    check(telar::clipboard::runCli(static_cast<int>(arguments.size()), arguments.data()) == 1, "CLI reports missing content");

    std::string text = "UTF-8: áéíóú 🧵\n";

    text.append(std::size_t{128} * 1024, 'x');
    check(telarTestClipboardSetUtf8(text.data(), text.size()), "set large UTF-8 text");

    result = telar::clipboard::read();
    check(result.has_value(), "read text larger than 2048 bytes");
    check(result->mime_type == "text/plain;charset=utf-8", "text MIME type");
    check(result->bytes.size() == text.size() && std::memcmp(result->bytes.data(), text.data(), text.size()) == 0, "UTF-8 bytes preserved");
    checkFile(*result);
    const auto limited_text = telar::clipboard::read(text.size() - 1);

    check(!limited_text && limited_text.error() == telar::clipboard::ReadError::content_too_large, "text byte limit enforced");
    check(telar::clipboard::read(text.size()).has_value(), "text at exact byte limit accepted");

    isolated.clear();
    check(telarTestClipboardSetUtf8("", 0), "set empty text");
    result = telar::clipboard::read();
    check(result && result->bytes.empty(), "empty text remains valid");
    checkFile(*result);

    struct ImageFormat {
      std::uint8_t format;
      std::string_view mime_type;
    };

    const std::array formats{
        ImageFormat{.format = telar_test_clipboard_png, .mime_type = "image/png"},
        ImageFormat{.format = telar_test_clipboard_tiff, .mime_type = "image/tiff"},
        ImageFormat{.format = telar_test_clipboard_jpeg, .mime_type = "image/jpeg"},
    };

    for (const auto& format : formats) {
      std::vector<telar::clipboard::byte> encoded;

      isolated.clear();
      check(telarTestClipboardSetEncodedImage(format.format, true, &captureBytes, &encoded), "set image and alternate text");
      result = telar::clipboard::read();
      check(result.has_value(), "read encoded image");
      check(result->mime_type == format.mime_type, "image preferred over text with correct MIME type");
      check(result->bytes == encoded, "encoded image preserved without conversion");
      checkFile(*result);
      const auto limited_image = telar::clipboard::read(encoded.size() - 1);

      check(!limited_image && limited_image.error() == telar::clipboard::ReadError::content_too_large, "image byte limit enforced");
      check(telar::clipboard::read(encoded.size()).has_value(), "image at exact byte limit accepted");
    }

    isolated.clear();
    check(telarTestClipboardSetUnsupported(), "set unsupported content");
    result = telar::clipboard::read();
    check(!result && result.error() == telar::clipboard::ReadError::no_supported_content, "unsupported content rejected");

    std::puts("Passed: large UTF-8 text, empty text, PNG, TIFF, JPEG, MIME types, image priority, exact CLI files and unsupported content. System clipboard unchanged.");
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
