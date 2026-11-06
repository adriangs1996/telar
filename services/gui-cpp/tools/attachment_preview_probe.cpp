#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include "../core/memory.hpp"
#include <array>
#include <cstddef>
#include <limits>
#include <span>
#include <exception>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.attachments.marker_input;
import telar.gui.graphics.pauses;

namespace {

using namespace telar::gui;

constexpr std::size_t fit_count = 16384;
constexpr std::uint64_t seed = 0x9e3779b97f4a7c15;
constexpr unsigned first_shift = 13;
constexpr unsigned second_shift = 7;
constexpr unsigned third_shift = 17;
constexpr std::array<std::array<std::uint32_t, 4>, 8> rectangles{
    std::array<std::uint32_t, 4>{1, 1, 1, 1},
    {2, 3, 2, 3},
    {3, 2, 2, 1},
    {17, 9, 7, 4},
    {64, 65, 13, 31},
    {257, 129, 256, 128},
    {70000, 1, 2048, 1},
    {1, 70000, 1, 256},
};

std::uint64_t randomWord(std::uint64_t &state) noexcept {
  state ^= state << first_shift;
  state ^= state >> second_shift;
  state ^= state << third_shift;

  return state;
}

void write(std::uint64_t value) {
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    std::cout.put(static_cast<char>((value >> (index * std::numeric_limits<unsigned char>::digits)) & std::numeric_limits<unsigned char>::max()));
  }
}

void observeSizing(std::uint64_t &random) {
  for (std::size_t index = 0; index < fit_count; ++index) {
    const auto width = static_cast<std::uint32_t>(randomWord(random)) | 1U;
    const auto height = static_cast<std::uint32_t>(randomWord(random)) | 1U;
    const auto size = AttachmentPreviewSize::fit(width, height, {.side = AttachmentPreviewSize::full_side, .pixels = AttachmentPreviewSize::full_pixels});
    for (const auto value : std::array{width, height, size.width, size.height}) {
      write(value);
    }
  }
}

void observePixels(std::uint64_t &random) {
  SystemAllocator memory;
  for (const auto shape : rectangles) {
    Vector<std::uint8_t, SystemAllocator> input{AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
    Vector<std::uint8_t, SystemAllocator> output{AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
    input.resize(static_cast<std::size_t>(shape[0]) * shape[1] * RgbaImageView::channels);
    output.resize(static_cast<std::size_t>(shape[2]) * shape[3] * RgbaImageView::channels);
    for (auto &byte : input) {
      byte = static_cast<std::uint8_t>(randomWord(random));
    }

    const RgbaImageView image{.pixels = std::as_bytes(std::span{input}), .stride = static_cast<std::size_t>(shape[0]) * RgbaImageView::channels, .width = shape[0], .height = shape[1]};
    if (!ArtworkResize::rectangle(image, output, shape[2], shape[3])) {
      throw std::runtime_error{"InvalidProbeShape"};
    }

    ArtworkResize::premultiply(output);
    for (const auto value : shape) {
      write(value);
    }

    for (const auto byte : output) {
      std::cout.put(static_cast<char>(byte));
    }
  }
}

}

int main() try {
  auto random = seed;
  observeSizing(random);
  observePixels(random);

  return std::cout.good() ? 0 : 1;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
