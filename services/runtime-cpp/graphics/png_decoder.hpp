#pragma once

#include <cstdint>

#include "../terminal/ghostty_handle.hpp"
#include <span>

namespace telar::runtime {

void installPngDecoder();
bool decodePngImage(const GhosttyAllocator *allocator, std::span<const std::uint8_t> bytes, GhosttySysImage &image, std::size_t limit = 128 * 1024 * 1024) noexcept;

}
