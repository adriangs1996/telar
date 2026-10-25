#pragma once

#include "decoder_memory.hpp"
#include "flate_container.hpp"
#include <zlib.h>

namespace telar::runtime {

template <Allocator Memory>
class FlateDecoder {
public:
  explicit FlateDecoder(Memory &memory) noexcept : memory_(memory) {
    stream_.zalloc = &DecoderMemory<Memory>::allocateArray;
    stream_.zfree = &DecoderMemory<Memory>::release;
    stream_.opaque = &memory_;
    initialized_ = inflateInit2(&stream_, -MAX_WBITS) == Z_OK;
  }

  ~FlateDecoder() {
    if (initialized_) {
      inflateEnd(&stream_);
    }
  }

  FlateDecoder(const FlateDecoder &) = delete;
  FlateDecoder &operator=(const FlateDecoder &) = delete;

  static constexpr std::size_t history_bytes = 32768;
  static constexpr std::size_t minimum_output_capacity = 2 * history_bytes;

  static std::size_t outputCapacity(std::size_t requested) noexcept {
    if (requested <= minimum_output_capacity) {
      return minimum_output_capacity;
    }
    const auto remainder = requested % history_bytes;
    const auto padding = remainder == 0 ? 0 : history_bytes - remainder;
    return requested > std::numeric_limits<std::size_t>::max() - padding ? requested : requested + padding;
  }

  std::optional<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept {
    const auto offset = FlateEnvelope::bodyOffset(input, container);
    if (!initialized_ || !offset || input.size() > std::numeric_limits<uInt>::max() || output.size() > std::numeric_limits<uInt>::max()) {
      return std::nullopt;
    }

    // Capture in the reference consumes these checksums without validating them.
    // Parsing the envelope separately preserves that best-effort observation contract.
    input = input.subspan(*offset);
    stream_.next_in = const_cast<Bytef *>(input.data());
    stream_.avail_in = static_cast<uInt>(input.size());
    stream_.next_out = output.data();
    stream_.avail_out = static_cast<uInt>(output.size());
    auto kind = blockKind(input, 0);
    // Finishing one complete block lets zlib skip allocating its retained history window.
    const bool single_block = !input.empty() && (input.front() & final_block_flag) != 0;
    const auto flush = single_block ? Z_FINISH : Z_BLOCK;
    for (;;) {
      const auto previous_input = stream_.total_in;
      const auto previous_output = stream_.total_out;
      const auto status = inflate(&stream_, flush);
      if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) {
        return std::nullopt;
      }

      const auto produced = output.size() - stream_.avail_out;
      if (stream_.avail_out == 0 || (kind == BlockKind::stored && produced >= requested)) {
        return produced;
      }
      if (status == Z_STREAM_END) {
        return stream_.avail_in >= FlateEnvelope::footerSize(container) ? std::optional{produced} : std::nullopt;
      }
      if (previous_input == stream_.total_in && previous_output == stream_.total_out) {
        return std::nullopt;
      }
      if ((stream_.data_type & block_boundary) != 0 && (stream_.data_type & final_block) == 0) {
        const auto bit_offset = stream_.total_in * bits_per_byte - (stream_.data_type & unused_bits_mask);
        kind = blockKind(input, bit_offset);
      }
    }
  }

private:
  enum class BlockKind { stored,
                         fixed,
                         dynamic,
                         invalid };

  static BlockKind blockKind(std::span<const std::uint8_t> input, std::size_t bit_offset) noexcept {
    unsigned kind = 0;
    for (std::size_t bit = 0; bit < block_kind_bits; ++bit) {
      const auto position = bit_offset + 1 + bit;
      if (position / bits_per_byte >= input.size()) {
        return BlockKind::invalid;
      }
      kind |= ((input[position / bits_per_byte] >> (position % bits_per_byte)) & 1) << bit;
    }
    return static_cast<BlockKind>(kind);
  }

  static constexpr std::size_t bits_per_byte = 8;
  static constexpr std::size_t block_kind_bits = 2;
  static constexpr unsigned final_block_flag = 1;
  static constexpr int block_boundary = 128;
  static constexpr int final_block = 64;
  static constexpr int unused_bits_mask = 63;
  DecoderMemory<Memory> memory_;
  z_stream stream_{};
  bool initialized_ = false;
};

template <Allocator Memory>
FlateDecoder(Memory &memory) -> FlateDecoder<Memory>;

}
