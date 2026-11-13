#pragma once

#include <cstdint>

#include "tbc/view.hpp"

#include "../terminal/ghostty_handle.hpp"
#include <span>

namespace telar::runtime {

void installPngDecoder();
// The decoded pixels are a block of the allocator, region `a`, that the image keeps.
bool decodePngImage(tbc::view<const GhosttyAllocator *, tbc::lt::a> allocator, std::span<const std::uint8_t> bytes, tbc::view<GhosttySysImage &, tbc::lt::a> image, std::size_t limit = 128 * 1024 * 1024) noexcept;

}
