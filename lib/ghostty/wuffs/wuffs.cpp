module;
#include <ghostty/wuffs-v0.4.h>

module telar.ghostty.wuffs;

import std;

namespace telar::ghostty::wuffs {

  bool isOk(const wuffs_base__status* status) noexcept {
    return wuffs_base__status__is_ok(status);
  }

  wuffs_base__slice_u8 makeSlice(std::uint8_t* pointer, std::size_t length) noexcept {
    return wuffs_base__make_slice_u8(pointer, length);
  }

  std::uint32_t pixelWidth(const wuffs_base__pixel_config* config) noexcept {
    return wuffs_base__pixel_config__width(config);
  }

  std::uint32_t pixelHeight(const wuffs_base__pixel_config* config) noexcept {
    return wuffs_base__pixel_config__height(config);
  }

  void setPixelConfig(wuffs_base__pixel_config* config, std::uint32_t format, std::uint32_t subsampling, std::uint32_t width, std::uint32_t height) noexcept {
    wuffs_base__pixel_config__set(config, format, subsampling, width, height);
  }

  wuffs_base__status setPixelBuffer(wuffs_base__pixel_buffer* buffer, const wuffs_base__pixel_config* config, wuffs_base__slice_u8 memory) noexcept {
    return wuffs_base__pixel_buffer__set_from_slice(buffer, config, memory);
  }

}
