#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <freetype/freetype.h>
#include <hb.h>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <ghostty/vt/unicode.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <cstdio>

#include "platform/font.h"

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.platform.primitives;
import telar.gui.fonts.face;
import telar.gui.presentation.history_meta_geometry;
import telar.platform;
import telar.gui.text.bounded_editor;
import telar.gui.text.json_unsigned_integer;

namespace {

using namespace telar::gui;

constexpr std::size_t expected_argument_count = 2;
constexpr std::uint32_t maximum_text_bytes = 4096;
constexpr std::uint32_t maximum_pixel_height = 4096;

enum class RequestKind : std::uint8_t {
  fit,
  graphemes,
  notification,
};

struct Request {
  std::uint32_t kind = static_cast<std::uint32_t>(RequestKind::fit);
  std::uint32_t pixel_height = 0;
  float width = 0;
  std::uint32_t text_bytes = 0;
};

static_assert(std::endian::native == std::endian::little);
static_assert(sizeof(Request) == sizeof(std::uint32_t) * 4);

bool readRequest(Request &request) {
  const auto bytes = std::fread(&request, sizeof(char), sizeof(request), stdin);
  if (bytes == 0 && std::feof(stdin) != 0) {
    return false;
  }

  if (bytes != sizeof(request)) {
    throw std::runtime_error{"IncompleteTextFitRequest"};
  }

  if (request.kind > static_cast<std::uint32_t>(RequestKind::notification) || request.pixel_height == 0 || request.pixel_height > maximum_pixel_height || !std::isfinite(request.width) || request.text_bytes > maximum_text_bytes) {
    throw std::invalid_argument{"InvalidTextFitRequest"};
  }

  return true;
}

void writeNumber(std::uint32_t value) {
  if (std::fwrite(std::addressof(value), sizeof(value), 1, stdout) != 1) {
    throw std::runtime_error{"TextFitOutputFailed"};
  }
}

void writeText(std::string_view text) {
  writeNumber(static_cast<std::uint32_t>(text.size()));
  if (!text.empty() && std::fwrite(text.data(), sizeof(char), text.size(), stdout) != text.size()) {
    throw std::runtime_error{"TextFitOutputFailed"};
  }
}

void writeGraphemes(std::string_view text) {
  GraphemeCursor cursor{text};
  while (const auto cluster = cursor.next()) {
    writeText(*cluster);
  }

  writeNumber(0);
}

void writeFit(fonts::Face &face, std::string_view text, const Request &request) {
  const auto measure = [&](std::string_view label) {
    return static_cast<float>(face.shape(label, static_cast<std::uint16_t>(request.pixel_height)).advance());
  };
  TextFit::Buffer buffer{};
  writeText(TextFit::fit(text, request.width, measure, buffer));
}

void writeNotification(fonts::Face &face, std::string_view text, const Request &request) {
  const auto measure = [&](std::string_view label) {
    return static_cast<float>(face.shape(label, static_cast<std::uint16_t>(request.pixel_height)).advance());
  };
  NotificationText wrapped;
  wrapped.wrap(text, request.width, measure);
  writeNumber(static_cast<std::uint32_t>(wrapped.count()));
  for (std::size_t index = 0; index < wrapped.count(); ++index) {
    writeText(wrapped.line(index));
  }
}

}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  if (arguments.size() != expected_argument_count) {
    return 1;
  }

  try {
    SystemAllocator memory;
    const auto source = telar::runtime::readFile(memory, arguments[1], telar_font_max_bytes);
    const Vector<std::uint8_t, SystemAllocator> bytes{source.cbegin(), source.cend(), AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
    fonts::Face face{bytes};
    String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
    Request request;
    while (readRequest(request)) {
      text.resize(request.text_bytes);
      if (std::fread(text.data(), sizeof(char), text.size(), stdin) != text.size()) {
        throw std::runtime_error{"IncompleteTextFitInput"};
      }

      if (request.kind == static_cast<std::uint32_t>(RequestKind::graphemes)) {
        writeGraphemes(text);
      } else if (request.kind == static_cast<std::uint32_t>(RequestKind::notification)) {
        writeNotification(face, text, request);
      } else {
        writeFit(face, text, request);
      }
    }

    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
