#include "png_decoder.hpp"
#include "storage.hpp"
#include <bit>
#include <csetjmp>
#include <cstring>
#include <png.h>

namespace telar::runtime {
namespace {

struct PngInput {
  const GhosttyAllocator *allocator;
  const Byte *bytes;
  std::size_t remaining;
  std::size_t limit;
};

struct alignas(std::max_align_t) PngAllocation {
  std::size_t length;
};

constexpr auto allocation_alignment = static_cast<std::uint8_t>(std::countr_zero(alignof(PngAllocation)));

void *allocatePng(png_structp decoder, png_alloc_size_t size) {
  const auto *input = static_cast<const PngInput *>(png_get_mem_ptr(decoder));
  if (input->limit < sizeof(PngAllocation) || size > input->limit - sizeof(PngAllocation)) {
    return nullptr;
  }
  const auto length = size + sizeof(PngAllocation);
  auto *allocation = static_cast<PngAllocation *>(input->allocator->vtable->alloc(input->allocator->ctx, length, allocation_alignment, 0));
  if (allocation == nullptr) {
    return nullptr;
  }
  allocation->length = length;
  return allocation + 1;
}

void freePng(png_structp decoder, void *pointer) {
  if (pointer == nullptr) {
    return;
  }
  const auto *input = static_cast<const PngInput *>(png_get_mem_ptr(decoder));
  auto *allocation = static_cast<PngAllocation *>(pointer) - 1;
  input->allocator->vtable->free(input->allocator->ctx, allocation, allocation->length, allocation_alignment, 0);
}

void readPng(png_structp decoder, png_bytep output, png_size_t length) {
  auto *input = static_cast<PngInput *>(png_get_io_ptr(decoder));
  if (length > input->remaining) {
    png_error(decoder, "Truncated PNG");
  }
  std::memcpy(output, input->bytes, length);
  input->bytes += length;
  input->remaining -= length;
}

void failPng(png_structp decoder, png_const_charp) {
  png_longjmp(decoder, 1);
}

void warnPng(png_structp, png_const_charp) {}

bool decodePng(void *context, const GhosttyAllocator *allocator, const Byte *bytes, std::size_t length, GhosttySysImage *image) {
  const auto limit = context == nullptr ? graphics_screen_bytes : *static_cast<const std::size_t *>(context);
  PngInput input{allocator, bytes, length, limit};
  png_structp decoder = png_create_read_struct_2(PNG_LIBPNG_VER_STRING, nullptr, failPng, warnPng, &input, allocatePng, freePng);
  if (decoder == nullptr) {
    return false;
  }
  png_infop info = png_create_info_struct(decoder);
  if (info == nullptr) {
    png_destroy_read_struct(&decoder, nullptr, nullptr);
    return false;
  }

  // libpng uses longjmp: no C++ object with a destructor may span this boundary.
  Byte *volatile pixels = nullptr;
  volatile std::size_t pixel_bytes = 0;
  if (setjmp(png_jmpbuf(decoder))) {
    if (pixels != nullptr) {
      ghostty_free(allocator, pixels, pixel_bytes);
    }
    png_destroy_read_struct(&decoder, &info, nullptr);
    return false;
  }

  png_set_read_fn(decoder, &input, readPng);
  png_set_user_limits(decoder, 32768, 32768);
  png_read_info(decoder, info);
  const auto width = png_get_image_width(decoder, info);
  const auto height = png_get_image_height(decoder, info);
  if (width == 0 || height == 0 || std::uint64_t{width} * height * 4 > input.limit) {
    png_error(decoder, "PNG exceeds image budget");
  }
  const int depth = png_get_bit_depth(decoder, info);
  const int color = png_get_color_type(decoder, info);
  if (depth == 16) {
    png_set_strip_16(decoder);
  }
  if (color == PNG_COLOR_TYPE_PALETTE) {
    png_set_palette_to_rgb(decoder);
  }
  if (color == PNG_COLOR_TYPE_GRAY && depth < 8) {
    png_set_expand_gray_1_2_4_to_8(decoder);
  }
  const bool transparent = png_get_valid(decoder, info, PNG_INFO_tRNS) != 0;
  if (transparent) {
    png_set_tRNS_to_alpha(decoder);
  }
  if (color == PNG_COLOR_TYPE_GRAY || color == PNG_COLOR_TYPE_GRAY_ALPHA) {
    png_set_gray_to_rgb(decoder);
  }
  if ((color & PNG_COLOR_MASK_ALPHA) == 0 && !transparent) {
    png_set_add_alpha(decoder, 255, PNG_FILLER_AFTER);
  }
  const int passes = png_set_interlace_handling(decoder);
  png_read_update_info(decoder, info);
  const std::size_t stride = static_cast<std::size_t>(width) * 4;
  if (png_get_rowbytes(decoder, info) != stride) {
    png_error(decoder, "Unexpected PNG stride");
  }
  pixel_bytes = stride * height;
  pixels = ghostty_alloc(allocator, pixel_bytes);
  if (pixels == nullptr) {
    png_error(decoder, "PNG allocation failed");
  }
  std::memset(pixels, 0, pixel_bytes);
  for (int pass = 0; pass < passes; ++pass) {
    for (std::uint32_t row = 0; row < height; ++row) {
      png_read_row(decoder, pixels + row * stride, nullptr);
    }
  }
  png_read_end(decoder, info);
  png_destroy_read_struct(&decoder, &info, nullptr);
  *image = GhosttySysImage{.width = width,
                           .height = height,
                           .data = pixels,
                           .data_len = pixel_bytes};
  return true;
}

}

bool decodePngImage(const GhosttyAllocator *allocator, std::span<const std::uint8_t> bytes, GhosttySysImage &image, std::size_t limit) {
  return decodePng(&limit, allocator, bytes.data(), bytes.size(), &image);
}

void installPngDecoder() {
  checkGhostty(ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, reinterpret_cast<const void *>(&decodePng)));
}

}
