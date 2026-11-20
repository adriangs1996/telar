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

  tbc::val_static<wuffs_base__status> setPixelBuffer(wuffs_base__pixel_buffer* buffer, const wuffs_base__pixel_config* config, wuffs_base__slice_u8 memory) noexcept {
    return wuffs_base__pixel_buffer__set_from_slice(buffer, config, memory);
  }

  tbc::val_static<wuffs_base__status> decodeImageConfig(wuffs_png__decoder* decoder, wuffs_base__image_config* config, wuffs_base__io_buffer* source) noexcept {
    return wuffs_png__decoder__decode_image_config(decoder, config, source);
  }

  tbc::val_static<wuffs_base__status> decodeFrame(wuffs_png__decoder* decoder, wuffs_base__pixel_buffer* destination, wuffs_base__io_buffer* source, std::uint32_t blend, wuffs_base__slice_u8 workspace) noexcept {
    return wuffs_png__decoder__decode_frame(decoder, destination, source, static_cast<wuffs_base__pixel_blend>(blend), workspace, nullptr);
  }

}
