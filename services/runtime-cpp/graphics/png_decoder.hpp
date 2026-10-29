#pragma once

#include "../terminal/ghostty_handle.hpp"
#include <span>

namespace telar::runtime {

void installPngDecoder();
bool decodePngImage(const GhosttyAllocator *allocator, std::span<const std::uint8_t> bytes, GhosttySysImage &image);

}
