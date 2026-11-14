module;
#include <ghostty/wuffs-v0.4.h>

export module telar.ghostty.wuffs;

import std;

// The PNG codec of the pinned libghostty-vt archive. Its header stays in this global module
// fragment only; importers decode through these declarations instead of including it.
export {
  using ::sizeof__wuffs_png__decoder;
  using ::wuffs_base__image_config;
  using ::wuffs_base__io_buffer;
  using ::wuffs_base__pixel_buffer;
  using ::wuffs_base__pixel_config;
  using ::wuffs_base__slice_u8;
  using ::wuffs_base__status;
  using ::wuffs_png__decoder;
  using ::wuffs_png__decoder__decode_frame;
  using ::wuffs_png__decoder__decode_image_config;
  using ::wuffs_png__decoder__initialize;
  using ::wuffs_png__decoder__workbuf_len;
}

// The header's helpers are static inline, so no importer can call them: these functions in
// wuffs.cpp call them for it.
export namespace telar::ghostty::wuffs {
  bool isOk(const wuffs_base__status* status) noexcept;
  wuffs_base__slice_u8 makeSlice(std::uint8_t* pointer, std::size_t length) noexcept;
  std::uint32_t pixelWidth(const wuffs_base__pixel_config* config) noexcept;
  std::uint32_t pixelHeight(const wuffs_base__pixel_config* config) noexcept;
  void setPixelConfig(wuffs_base__pixel_config* config, std::uint32_t format, std::uint32_t subsampling, std::uint32_t width, std::uint32_t height) noexcept;
  wuffs_base__status setPixelBuffer(wuffs_base__pixel_buffer* buffer, const wuffs_base__pixel_config* config, wuffs_base__slice_u8 memory) noexcept;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name.
#define TELAR_WUFFS_CONSTANTS(X)                            \
  X(WUFFS_BASE__PIXEL_BLEND__SRC)                           \
  X(WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL)               \
  X(WUFFS_BASE__PIXEL_SUBSAMPLING__NONE)                    \
  X(WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED) \
  X(WUFFS_VERSION)

namespace telar::ghostty::wuffs::captured {

#define TELAR_WUFFS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_WUFFS_CONSTANTS(TELAR_WUFFS_CAPTURE)

}

#undef WUFFS_BASE__PIXEL_BLEND__SRC
#undef WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL
#undef WUFFS_BASE__PIXEL_SUBSAMPLING__NONE
#undef WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED
#undef WUFFS_VERSION

#define TELAR_WUFFS_CONSTANT(name) inline constexpr auto name = telar::ghostty::wuffs::captured::name##_;

export {
  TELAR_WUFFS_CONSTANTS(TELAR_WUFFS_CONSTANT)
}
