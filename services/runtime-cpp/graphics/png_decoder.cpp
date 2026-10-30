#include "png_decoder.hpp"
#include "storage.hpp"
#include <ghostty/wuffs-v0.4.h>
#include <bit>
#include <cstddef>
#include <limits>
#include <utility>

namespace telar::runtime {
namespace {

enum class BufferAlignment : std::uint8_t {
  bytes = 0,
  native = std::countr_zero(alignof(std::max_align_t)),
};

class CodecBuffer {
public:
  explicit CodecBuffer(const GhosttyAllocator *allocator, std::size_t length, std::size_t limit, BufferAlignment alignment = BufferAlignment::native) noexcept
      : allocator_(allocator), length_(length), alignment_(static_cast<std::uint8_t>(alignment)) {
    if (length != 0 && length <= limit) {
      data_ = static_cast<Byte *>(allocator_->vtable->alloc(allocator_->ctx, length, alignment_, 0));
    }
  }

  ~CodecBuffer() {
    if (data_ != nullptr) {
      allocator_->vtable->free(allocator_->ctx, data_, length_, alignment_, 0);
    }
  }

  CodecBuffer(const CodecBuffer &) = delete;
  CodecBuffer &operator=(const CodecBuffer &) = delete;

  explicit operator bool() const noexcept { return length_ == 0 || data_ != nullptr; }
  Byte *data() const noexcept { return data_; }
  std::size_t size() const noexcept { return length_; }
  Byte *release() noexcept { return std::exchange(data_, nullptr); }

private:
  const GhosttyAllocator *allocator_;
  Byte *data_ = nullptr;
  std::size_t length_;
  std::uint8_t alignment_;
};

bool decodePng(void *context, const GhosttyAllocator *allocator, const Byte *bytes, std::size_t length, GhosttySysImage *image) noexcept {
  const auto limit = context == nullptr ? graphics_screen_bytes : *static_cast<const std::size_t *>(context);
  return decodePngImage(allocator, {bytes, length}, *image, limit);
}

}

// This is a generic image decoder, already linked in the pinned VT archive.
// Protocol recognition, validation policy and replies remain in native C++.
bool decodePngImage(const GhosttyAllocator *allocator, std::span<const std::uint8_t> bytes, GhosttySysImage &image, std::size_t limit) noexcept {
  static_assert(alignof(wuffs_png__decoder) <= alignof(std::max_align_t));
  CodecBuffer decoder_storage{allocator, sizeof__wuffs_png__decoder(), limit};
  if (!decoder_storage) {
    return false;
  }
  auto *decoder = reinterpret_cast<wuffs_png__decoder *>(decoder_storage.data());
  auto status = wuffs_png__decoder__initialize(decoder, decoder_storage.size(), WUFFS_VERSION, WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&status)) {
    return false;
  }

  wuffs_base__io_buffer source{
      .data = {.ptr = const_cast<Byte *>(bytes.data()), .len = bytes.size()},
      .meta = {.wi = bytes.size(), .ri = 0, .pos = 0, .closed = true},
  };
  wuffs_base__image_config config{};
  status = wuffs_png__decoder__decode_image_config(decoder, &config, &source);
  if (!wuffs_base__status__is_ok(&status)) {
    return false;
  }
  const auto width = wuffs_base__pixel_config__width(&config.pixcfg);
  const auto height = wuffs_base__pixel_config__height(&config.pixcfg);
  constexpr std::size_t pixel_bytes = 4;
  if (width == 0 || height == 0 || width > std::numeric_limits<std::size_t>::max() / pixel_bytes / height) {
    return false;
  }
  const auto length = static_cast<std::size_t>(width) * height * pixel_bytes;
  wuffs_base__pixel_config__set(&config.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, width, height);
  CodecBuffer pixels{allocator, length, limit, BufferAlignment::bytes};
  if (!pixels) {
    return false;
  }

  const auto work_length = wuffs_png__decoder__workbuf_len(decoder).max_incl;
  if (work_length > std::numeric_limits<std::size_t>::max()) {
    return false;
  }
  CodecBuffer workspace{allocator, static_cast<std::size_t>(work_length), limit};
  if (!workspace) {
    return false;
  }
  wuffs_base__pixel_buffer destination{};
  status = wuffs_base__pixel_buffer__set_from_slice(&destination, &config.pixcfg, wuffs_base__make_slice_u8(pixels.data(), pixels.size()));
  if (!wuffs_base__status__is_ok(&status)) {
    return false;
  }
  status = wuffs_png__decoder__decode_frame(decoder, &destination, &source, WUFFS_BASE__PIXEL_BLEND__SRC, wuffs_base__make_slice_u8(workspace.data(), workspace.size()), nullptr);
  if (!wuffs_base__status__is_ok(&status)) {
    return false;
  }

  image = GhosttySysImage{
      .width = width,
      .height = height,
      .data = pixels.release(),
      .data_len = length,
  };
  return true;
}

void installPngDecoder() {
  checkGhostty(ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<const void *>(&decodePng)));
}

}
