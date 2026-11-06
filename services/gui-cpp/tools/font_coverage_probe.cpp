#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <type_traits>
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <cstdio>

#include "core/memory.hpp"
#include "platform/font.h"


import telar.gui.core.unicode_scalar;
import telar.gui.fonts.face;
import telar.platform;

namespace {

using namespace telar::gui;

constexpr std::size_t expected_arguments = 3;
constexpr std::size_t bits_per_byte = 8;
constexpr std::size_t unicode_count = Utf8Scalar::maximum_codepoint + 1;
constexpr std::size_t bitmap_bytes = unicode_count / bits_per_byte;
constexpr std::array<char32_t, 3> outside_unicode{unicode_count, 0x1fffff, std::numeric_limits<char32_t>::max()};

fonts::FontMatch matchVariant(std::string_view variant) {
  fonts::FontMatch match{};
  if (variant == "wide") {
    constexpr std::uint32_t width_axis = 0x77647468;
    constexpr float wide_coordinate = 200;
    match.variation.count = 1;
    match.variation.tags[0] = width_axis;
    match.variation.values[0] = wide_coordinate;
  } else if (variant != "regular") {
    throw std::invalid_argument{"UnknownFontVariant"};
  }

  return match;
}

Vector<std::uint8_t, SystemAllocator> coverage(const fonts::Face &face, SystemAllocator &memory) {
  Vector<std::uint8_t, SystemAllocator> result(bitmap_bytes + outside_unicode.size(), 0, AllocatorRef<std::uint8_t, SystemAllocator>{memory});
  for (std::size_t scalar = 0; scalar < unicode_count; ++scalar) {
    if (face.covers(static_cast<char32_t>(scalar))) {
      result[scalar / bits_per_byte] |= static_cast<std::uint8_t>(1U << (scalar % bits_per_byte));
    }
  }

  for (std::size_t index = 0; index < outside_unicode.size(); ++index) {
    result[bitmap_bytes + index] = static_cast<std::uint8_t>(face.covers(outside_unicode[index]));
  }

  return result;
}

void exerciseFace(fonts::Face &face, std::uint16_t height) {
  static_cast<void>(face.metrics(height));
  constexpr std::string_view text = "AV fi e\u0301 \u4e2d \uf07b \U0001f600";
  const auto run = face.shape(text, height);
  for (std::size_t index = 0; index < run.size(); ++index) {
    static_cast<void>(face.rasterize({.index = run.glyph(index).index, .pixel_height = height, .style = {}}));
  }
}

void runProbe(const char *path, std::string_view variant) {
  SystemAllocator memory;
  const auto source = telar::runtime::readFile(memory, path, telar_font_max_bytes);
  const Vector<std::uint8_t, SystemAllocator> bytes{source.cbegin(), source.cend(), AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
  fonts::Face face{bytes, matchVariant(variant)};
  const auto expected = coverage(face, memory);
  constexpr std::array<std::uint16_t, 3> heights{9, 13, 31};
  for (const auto height : heights) {
    exerciseFace(face, height);
    if (coverage(face, memory) != expected) {
      throw std::runtime_error{"CoverageChangedAfterShaping"};
    }
  }

  if (std::fwrite(expected.data(), expected.size(), 1, stdout) != 1) {
    throw std::runtime_error{"CoverageOutputFailed"};
  }
}

}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    runProbe(arguments[1], arguments[2]);
    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));
    return 1;
  }
}
