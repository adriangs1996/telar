// Defines what telar.runtime.terminal.kitty declares outside any module.
import std;
import telar.ghostty.vt;
import telar.ghostty.wuffs;
import telar.tbc;
import telar.vocabulary;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.graphics_storage;
import telar.runtime.terminal.kitty;

namespace telar::runtime {
  namespace {

    enum class BufferAlignment : std::uint8_t {
      bytes = 0,
      native = std::countr_zero(alignof(std::max_align_t)),
    };

    // A block of the allocator, region `a`; once released it is the allocator's, as `Vec::leak` hands out.
    class CodecBuffer {
    public:
      explicit CodecBuffer(tbc::val_a<const GhosttyAllocator*> allocator, std::size_t length, std::size_t limit, BufferAlignment alignment = BufferAlignment::native) noexcept
          : allocator_(allocator),
            length_(length),
            alignment_(static_cast<std::uint8_t>(alignment)) {
        if (length != 0 && length <= limit) {
          data_ = allocator_->vtable->alloc(allocator_->ctx, length, alignment_, 0);
        }
      }

      ~CodecBuffer() {
        if (data_ != nullptr) {
          allocator_->vtable->free(allocator_->ctx, data_, length_, alignment_, 0);
        }
      }

      CodecBuffer(const CodecBuffer&) = delete;
      CodecBuffer& operator=(const CodecBuffer&) = delete;
      CodecBuffer(CodecBuffer&&) = delete;
      CodecBuffer& operator=(CodecBuffer&&) = delete;

      explicit operator bool() const noexcept {
        return length_ == 0 || data_ != nullptr;
      }

      // Not const: the codec writes through the block they return.
      [[nodiscard]] void* data() noexcept {
        return data_;
      }

      [[nodiscard]] Byte* bytes() noexcept {
        return static_cast<Byte*>(data_);
      }

      [[nodiscard]] std::size_t size() const noexcept {
        return length_;
      }

      tbc::val_a<Byte*> release() noexcept {
        return static_cast<Byte*>(std::exchange(data_, nullptr));
      }

    private:
      tbc::val_a<const GhosttyAllocator*> allocator_;
      tbc::val_a<void*> data_ = nullptr;
      std::size_t length_;
      std::uint8_t alignment_;
    };

    bool decodePng(void* context, tbc::val_a<const GhosttyAllocator*> allocator, const Byte* bytes, std::size_t length, tbc::val_a<GhosttySysImage*> image) noexcept { // NOLINT(misc-const-correctness): GhosttySysDecodePngFn's C signature takes a mutable userdata
      if (image == nullptr) {
        return false;
      }

      const auto limit = context == nullptr ? graphics_screen_bytes : *static_cast<const std::size_t*>(context);
      // GhosttySysDecodePngFn hands the PNG as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
      const std::span<const Byte> png{bytes, length};
#pragma clang unsafe_buffer_usage end

      return decodePngImage(allocator, png, *image, limit);
    }

  }

  // This is a generic image decoder, already linked in the pinned VT archive.
  // Protocol recognition, validation policy and replies remain in native C++.
  bool decodePngImage(tbc::val_a<const GhosttyAllocator*> allocator, std::span<const std::uint8_t> bytes, tbc::mut_a<GhosttySysImage> image, std::size_t limit) noexcept {
    static_assert(alignof(wuffs_png__decoder) <= alignof(std::max_align_t));
    CodecBuffer decoder_storage{allocator, sizeof__wuffs_png__decoder(), limit};
    if (!decoder_storage) {
      return false;
    }

    auto* decoder = static_cast<wuffs_png__decoder*>(decoder_storage.data());
    auto status = wuffs_png__decoder__initialize(decoder, decoder_storage.size(), WUFFS_VERSION, WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
    if (!ghostty::wuffs::isOk(&status)) {
      return false;
    }

    wuffs_base__io_buffer source{
        .data = {.ptr = tbc::raw(const_cast<Byte*>(bytes.data())), .len = bytes.size()}, // NOLINT(cppcoreguidelines-pro-type-const-cast): wuffs's io_buffer has no read-only form; the decoder only reads its source
        .meta = {.wi = bytes.size(), .ri = 0, .pos = 0, .closed = true},
    };

    wuffs_base__image_config config{};

    status = ghostty::wuffs::decodeImageConfig(decoder, &config, &source);
    if (!ghostty::wuffs::isOk(&status)) {
      return false;
    }

    const auto width = ghostty::wuffs::pixelWidth(&config.pixcfg);
    const auto height = ghostty::wuffs::pixelHeight(&config.pixcfg);
    constexpr std::size_t pixel_bytes = 4;
    if (width == 0 || height == 0 || width > std::numeric_limits<std::size_t>::max() / pixel_bytes / height) {
      return false;
    }

    const auto length = static_cast<std::size_t>(width) * height * pixel_bytes;

    ghostty::wuffs::setPixelConfig(&config.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, width, height);
    CodecBuffer pixels{allocator, length, limit, BufferAlignment::bytes};
    if (!pixels) {
      return false;
    }

    const auto work_length = wuffs_png__decoder__workbuf_len(decoder).max_incl;
    if (!std::in_range<std::size_t>(work_length)) {
      return false;
    }

    CodecBuffer workspace{allocator, static_cast<std::size_t>(work_length), limit};
    if (!workspace) {
      return false;
    }

    wuffs_base__pixel_buffer destination{};

    status = ghostty::wuffs::setPixelBuffer(&destination, &config.pixcfg, ghostty::wuffs::makeSlice(pixels.bytes(), pixels.size()));
    if (!ghostty::wuffs::isOk(&status)) {
      return false;
    }

    status = ghostty::wuffs::decodeFrame(decoder, &destination, &source, WUFFS_BASE__PIXEL_BLEND__SRC, ghostty::wuffs::makeSlice(workspace.bytes(), workspace.size()));
    if (!ghostty::wuffs::isOk(&status)) {
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
    checkGhostty(ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<const void*>(&decodePng))); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): ghostty_sys_set takes the callback as a const void*
  }

}
