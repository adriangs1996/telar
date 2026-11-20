module;
#include <ghostty/wuffs-v0.4.h>

export module telar.ghostty.wuffs;

import std;
import telar.tbc;

// The PNG codec of the pinned libghostty-vt archive. Its header stays in this global module
// fragment only; importers decode through these declarations instead of including it.
export {
  // NOLINTBEGIN(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp): wuffs's C API names its types and functions with double underscores.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreserved-identifier"
  using ::sizeof__wuffs_png__decoder;
  using ::wuffs_base__image_config;
  using ::wuffs_base__io_buffer;
  using ::wuffs_base__pixel_buffer;
  using ::wuffs_base__pixel_config;
  using ::wuffs_base__slice_u8;
  using ::wuffs_base__status;
  using ::wuffs_png__decoder;
  using ::wuffs_png__decoder__initialize;
  using ::wuffs_png__decoder__workbuf_len;
#pragma clang diagnostic pop
  // NOLINTEND(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp)
}

// The header's helpers are static inline, so no importer can call them: these functions in
// wuffs.cpp call them for it.
export namespace telar::ghostty::wuffs {
  bool isOk(const wuffs_base__status* status) noexcept;
  wuffs_base__slice_u8 makeSlice(std::uint8_t* pointer, std::size_t length) noexcept;
  std::uint32_t pixelWidth(const wuffs_base__pixel_config* config) noexcept;
  std::uint32_t pixelHeight(const wuffs_base__pixel_config* config) noexcept;
  void setPixelConfig(wuffs_base__pixel_config* config, std::uint32_t format, std::uint32_t subsampling, std::uint32_t width, std::uint32_t height) noexcept;
  tbc::val_static<wuffs_base__status> setPixelBuffer(wuffs_base__pixel_buffer* buffer, const wuffs_base__pixel_config* config, wuffs_base__slice_u8 memory) noexcept;
  // The decoder's statuses name static strings.
  tbc::val_static<wuffs_base__status> decodeImageConfig(wuffs_png__decoder* decoder, wuffs_base__image_config* config, wuffs_base__io_buffer* source) noexcept;
  tbc::val_static<wuffs_base__status> decodeFrame(wuffs_png__decoder* decoder, wuffs_base__pixel_buffer* destination, wuffs_base__io_buffer* source, std::uint32_t blend, wuffs_base__slice_u8 workspace) noexcept;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name.
namespace telar::ghostty::wuffs::captured {
  // The header's macros cast C-style.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wold-style-cast"
  inline constexpr auto pixel_blend_src = WUFFS_BASE__PIXEL_BLEND__SRC;
  inline constexpr auto pixel_format_rgba_nonpremul = WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL;
  inline constexpr auto pixel_subsampling_none = WUFFS_BASE__PIXEL_SUBSAMPLING__NONE;
  inline constexpr auto initialize_leave_internal_buffers_uninitialized = WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED;
  inline constexpr auto version = WUFFS_VERSION;
#pragma clang diagnostic pop
}

// The header names its macros with double underscores.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreserved-macro-identifier"
#undef WUFFS_BASE__PIXEL_BLEND__SRC
#undef WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL
#undef WUFFS_BASE__PIXEL_SUBSAMPLING__NONE
#undef WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED
#pragma clang diagnostic pop
#undef WUFFS_VERSION

export {
  // NOLINTBEGIN(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp,readability-identifier-naming): each constant keeps the name of the header's macro it replaces.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreserved-identifier"
  inline constexpr auto WUFFS_BASE__PIXEL_BLEND__SRC = telar::ghostty::wuffs::captured::pixel_blend_src;
  inline constexpr auto WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL = telar::ghostty::wuffs::captured::pixel_format_rgba_nonpremul;
  inline constexpr auto WUFFS_BASE__PIXEL_SUBSAMPLING__NONE = telar::ghostty::wuffs::captured::pixel_subsampling_none;
  inline constexpr auto WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED = telar::ghostty::wuffs::captured::initialize_leave_internal_buffers_uninitialized;
  inline constexpr auto WUFFS_VERSION = telar::ghostty::wuffs::captured::version;
#pragma clang diagnostic pop
  // NOLINTEND(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp,readability-identifier-naming)
}
