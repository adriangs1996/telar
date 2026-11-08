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
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <cstdio>

#include "platform/font.h"

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.platform.primitives;
import telar.gui.fonts.face;
import telar.platform;

namespace {

using namespace telar::gui;

constexpr std::size_t expected_argument_count = 3;
constexpr std::uint32_t maximum_text_bytes = 4096;
constexpr std::uint32_t maximum_pixel_height = 4096;
constexpr std::uint32_t bold_style_bit = 1;
constexpr std::uint32_t italic_style_bit = 1U << 1U;
constexpr auto all_style_bits = bold_style_bit | italic_style_bit;
constexpr std::uint32_t width_axis = 0x77647468;
constexpr float wide_coordinate = 200;

enum class RunStatus : std::uint8_t {
  shaped = 1,
  rejected = 2,
};

struct Request {
  std::uint32_t pixel_height = 0;
  std::uint32_t style_mask = 0;
  std::uint32_t text_bytes = 0;
};

static_assert(std::endian::native == std::endian::little);
static_assert(sizeof(Request) == sizeof(std::uint32_t) * 3);

bool readRequest(Request &request) {
  const auto count = std::fread(&request, sizeof(char), sizeof(request), stdin);
  if (count == 0 && std::feof(stdin) != 0) {
    return false;
  }

  if (count != sizeof(request)) {
    throw std::runtime_error{"IncompleteShapingRequest"};
  }

  if (request.pixel_height == 0 || request.pixel_height > maximum_pixel_height || request.style_mask > all_style_bits || request.text_bytes > maximum_text_bytes) {
    throw std::invalid_argument{"InvalidShapingRequest"};
  }

  return true;
}

template <typename Value>
void write(const Value &value) {
  if (std::fwrite(std::addressof(value), sizeof(Value), 1, stdout) != 1) {
    throw std::runtime_error{"ShapingOutputFailed"};
  }
}

void writeBitmap(fonts::GlyphBitmapView bitmap) {
  write(std::array{static_cast<std::int32_t>(bitmap.width), static_cast<std::int32_t>(bitmap.height), bitmap.left, bitmap.top});
  for (std::uint32_t row = 0; row < bitmap.height; ++row) {
    const auto pixels = bitmap.row(row);
    if (std::fwrite(pixels.data(), sizeof(std::uint8_t), pixels.size(), stdout) != pixels.size()) {
      throw std::runtime_error{"ShapingOutputFailed"};
    }
  }
}

void writeRun(fonts::Face &face, std::string_view text, const Request &request) {
  const auto height = static_cast<std::uint16_t>(request.pixel_height);
  // Reading metrics and rasterizing reach the face, so the shaped run is copied first.
  std::vector<fonts::ShapedGlyph> glyphs;
  std::int32_t advance = 0;
  bool right_to_left = false;
  {
    const auto run = face.shape(text, height);
    advance = run.advance();
    right_to_left = run.rightToLeft();
    glyphs.reserve(run.size());
    for (std::size_t index = 0; index < run.size(); ++index) {
      glyphs.push_back(run.glyph(index));
    }
  }

  const auto metrics = face.metrics(height);
  write(std::array{static_cast<std::int32_t>(RunStatus::shaped), metrics.ascender, static_cast<std::int32_t>(metrics.line_height), static_cast<std::int32_t>(metrics.maximum_advance), static_cast<std::int32_t>(glyphs.size()), advance});
  write(static_cast<std::uint32_t>(right_to_left));
  const fonts::GlyphStyle style{.bold = (request.style_mask & bold_style_bit) != 0, .italic = (request.style_mask & italic_style_bit) != 0};
  for (const auto &glyph : glyphs) {
    write(std::array{static_cast<std::int32_t>(glyph.index), static_cast<std::int32_t>(glyph.cluster), glyph.x_advance, glyph.y_advance, glyph.x_offset, glyph.y_offset});
    writeBitmap(face.rasterize({.index = glyph.index, .pixel_height = height, .style = style}));
  }
}

fonts::FontMatch matchVariant(std::string_view name) {
  fonts::FontMatch match{};
  if (name == "wide") {
    match.variation.count = 1;
    match.variation.tags[0] = width_axis;
    match.variation.values[0] = wide_coordinate;
  } else if (name != "regular") {
    throw std::invalid_argument{"UnknownFontVariant"};
  }

  return match;
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
    fonts::Face face{bytes, matchVariant(arguments[2])};
    String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
    Request request;
    while (readRequest(request)) {
      text.resize(request.text_bytes);
      if (std::fread(text.data(), sizeof(char), text.size(), stdin) != text.size()) {
        throw std::runtime_error{"IncompleteShapingText"};
      }

      try {
        writeRun(face, text, request);
      } catch (const telar::EncodingError &) {
        write(static_cast<std::int32_t>(RunStatus::rejected));
      }
    }

    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
