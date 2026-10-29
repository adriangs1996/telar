#pragma once

#include "core/memory.hpp"
#include "font_source.hpp"
#include "fonts/native_match.hpp"
#include <cstdint>
#include <span>

namespace telar::gui::qt {

class FontAsset {
public:
  explicit FontAsset(const FontData &data)
      : bytes_(data.bytes.cbegin(), data.bytes.cend(), AllocatorRef<std::uint8_t, SystemAllocator>{memory_}),
        match_(data.match) {}

  ~FontAsset() = default;
  FontAsset(const FontAsset &) = delete;
  FontAsset &operator=(const FontAsset &) = delete;
  FontAsset(FontAsset &&) = delete;
  FontAsset &operator=(FontAsset &&) = delete;

  [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
    return bytes_;
  }

  [[nodiscard]] const fonts::FontMatch &match() const noexcept {
    return match_;
  }

private:
  SystemAllocator memory_;
  Vector<std::uint8_t, SystemAllocator> bytes_;
  fonts::FontMatch match_;
};

}
