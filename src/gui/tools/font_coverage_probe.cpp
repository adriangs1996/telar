#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "platform/font.h"
#include "tbc/view.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>
#include <vector>

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.platform.fs;
import telar.base.ds;

namespace {

  using namespace telar::gui;

  constexpr std::size_t expected_arguments = 3;
  constexpr std::size_t bits_per_byte = 8;
  constexpr std::size_t unicode_count = Utf8Scalar::maximum_codepoint + 1;
  constexpr std::size_t bitmap_bytes = unicode_count / bits_per_byte;
  constexpr telar::ds::Array<char32_t, 3> outside_unicode{unicode_count, 0x1fffff, std::numeric_limits<char32_t>::max()};

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

  // The bitmap is allocated from memory, region `a`.
  tbc::val_a<telar::ds::Vec<std::uint8_t, SystemAllocator>> coverage(const fonts::Face& face, tbc::mut_a<SystemAllocator> memory) {
    telar::ds::Vec<std::uint8_t, SystemAllocator> result{memory};

    result.resize(bitmap_bytes + outside_unicode.size());

    for (std::size_t scalar = 0; scalar < unicode_count; ++scalar) {
      if (face.covers(static_cast<char32_t>(scalar))) {
        result.atMut(scalar / bits_per_byte) |= static_cast<std::uint8_t>(1U << (scalar % bits_per_byte));
      }
    }

    for (std::size_t index = 0; index < outside_unicode.size(); ++index) {
      result.atMut(bitmap_bytes + index) = static_cast<std::uint8_t>(face.covers(outside_unicode[index]));
    }

    return result;
  }

  // The bytes are allocated from memory, region `a`.
  tbc::val_a<telar::ds::Vec<std::uint8_t, SystemAllocator>> fontBytes(std::string_view source, tbc::mut_a<SystemAllocator> memory) {
    telar::ds::Vec<std::uint8_t, SystemAllocator> result{memory};

    result.resize(source.size());
    std::ranges::copy(source, result.viewMut().begin());
    return result;
  }

  void exerciseFace(fonts::Face& face, std::uint16_t height) {
    static_cast<void>(face.metrics(height));
    constexpr std::string_view text = "AV fi e\u0301 \u4e2d \uf07b \U0001f600";
    // Rasterizing reaches the face, so the shaped glyphs are copied first.
    std::vector<std::uint32_t> glyphs;

    {
      const auto run = face.shape(text, height);

      glyphs.reserve(run.size());
      for (std::size_t index = 0; index < run.size(); ++index) {
        glyphs.push_back(run.glyph(index).index);
      }
    }

    for (const auto glyph : glyphs) {
      static_cast<void>(face.rasterize({.index = glyph, .pixel_height = height, .style = {}}));
    }
  }

  void runProbe(const char* path, std::string_view variant) {
    SystemAllocator memory;
    const auto source = telar::runtime::readFile(memory, path, telar_font_max_bytes);
    const auto bytes = fontBytes(source.view(), memory);
    fonts::Face face{bytes, matchVariant(variant)};
    const auto expected = coverage(face, memory);
    constexpr telar::ds::Array<std::uint16_t, 3> heights{9, 13, 31};

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

int main(int argc, char** argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    runProbe(arguments[1], arguments[2]);
    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception& error) {
    static_cast<void>(std::fputs(error.what(), stderr));
    return 1;
  }
}
