#pragma once

#include "../memory/sensitive_allocation.hpp"
#include "decoder_memory.hpp"
#include "zstd_block.hpp"
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>

namespace telar::runtime {

template <Allocator Memory>
class ZstdDecoder {
public:
  struct Result {
    std::size_t bytes;
    bool truncated;
  };

  explicit ZstdDecoder(Memory &memory) noexcept : allocator_(memory), memory_(memory) {
    state_ = ZSTD_createDCtx_advanced({&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_});
    if (state_ != nullptr) {
      ZSTD_DCtx_setParameter(state_, ZSTD_d_forceIgnoreChecksum, ZSTD_d_ignoreChecksum);
    }
  }

  ~ZstdDecoder() { ZSTD_freeDCtx(state_); }

  ZstdDecoder(const ZstdDecoder &) = delete;
  ZstdDecoder &operator=(const ZstdDecoder &) = delete;

  std::optional<Result> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, std::size_t limit) {
    if (state_ == nullptr) {
      return std::nullopt;
    }
    std::size_t produced = 0;
    while (!input.empty()) {
      ZSTD_frameHeader frame{};
      const auto header = ZSTD_getFrameHeader(&frame, input.data(), input.size());
      if (header != 0 || frame.windowSize > maximum_window_bytes || (frame.frameType == ZSTD_frame && (input[frame_descriptor_offset] & dictionary_flags) != 0)) {
        return std::nullopt;
      }
      if (ZSTD_isError(ZSTD_decompressBegin(state_))) {
        return std::nullopt;
      }

      ZstdBlock block;
      const auto frame_start = produced;
      const bool known_size = frame.frameType == ZSTD_frame && frame.frameContentSize != ZSTD_CONTENTSIZE_UNKNOWN;
      while (const auto needed = ZSTD_nextSrcSizeToDecompress(state_)) {
        const auto kind = ZSTD_nextInputType(state_);
        const auto remaining = limit - produced;
        if (needed > input.size()) {
          if ((kind == ZSTDnit_block || kind == ZSTDnit_lastBlock) && block.kind == ZstdBlock::Kind::raw && input.size() >= remaining && needed > remaining) {
            std::copy_n(input.data(), remaining, output.data() + produced);
            return Result{limit, true};
          }
          return std::nullopt;
        }

        bool requires_block_capacity = false;
        if (kind == ZSTDnit_blockHeader) {
          block = ZstdBlock::parse(input.first<3>());
          if (block.size > frame.blockSizeMax) {
            return std::nullopt;
          }
        } else if ((kind == ZSTDnit_block || kind == ZSTDnit_lastBlock) && block.kind == ZstdBlock::Kind::compressed) {
          const auto literals = ZstdBlock::literals(input.first(needed));
          if (!literals) {
            return std::nullopt;
          }
          requires_block_capacity = literals->has_sequences;
          if (!literals->has_sequences && literals->regenerated_size > remaining) {
            const auto copied = copyLiteralPrefix(input.first(needed), output.subspan(produced, remaining), frame.blockSizeMax);
            return copied ? std::optional{Result{produced + *copied, true}} : std::nullopt;
          }
        }

        // A full capture stops at the writer boundary before later frame validation.
        if ((kind == ZSTDnit_block || kind == ZSTDnit_lastBlock) && block.kind != ZstdBlock::Kind::compressed && block.size > remaining) {
          if (block.kind == ZstdBlock::Kind::raw) {
            std::copy_n(input.data(), remaining, output.data() + produced);
          } else if (block.kind == ZstdBlock::Kind::repeated) {
            std::fill_n(output.data() + produced, remaining, input.front());
          } else {
            return std::nullopt;
          }
          return Result{limit, true};
        }
        // The reference reserves a complete output block before expanding sequences.
        if (requires_block_capacity && remaining < frame.blockSizeMax) {
          return Result{produced, true};
        }
        const auto decoded = ZSTD_decompressContinue(state_, output.data() + produced, output.size() - produced, input.data(), needed);
        if (ZSTD_isError(decoded)) {
          return std::nullopt;
        }
        if (decoded > remaining) {
          return Result{limit, true};
        }
        produced += decoded;
        if (known_size && produced - frame_start > frame.frameContentSize) {
          return std::nullopt;
        }
        input = input.subspan(needed);
      }
      if (known_size && produced - frame_start != frame.frameContentSize) {
        return std::nullopt;
      }
    }
    return Result{produced, false};
  }

  static constexpr std::size_t minimum_output_capacity = 128 * 1024;

  static std::size_t outputCapacity(std::span<const std::uint8_t> input, std::size_t logical_capacity) noexcept {
    if (logical_capacity > minimum_output_capacity) {
      return logical_capacity;
    }

    const auto content_size = ZSTD_getFrameContentSize(input.data(), input.size());
    if (content_size >= logical_capacity || ZSTD_findFrameCompressedSize(input.data(), input.size()) != input.size()) {
      return logical_capacity;
    }

    return std::max<std::size_t>(1, content_size);
  }

private:
  std::optional<std::size_t> copyLiteralPrefix(std::span<const std::uint8_t> input, std::span<std::uint8_t> destination, std::size_t block_capacity) {
    SensitiveAllocation storage{allocator_, block_capacity};
    const auto decoded = ZSTD_decompressContinue(state_, storage.bytes().data(), storage.bytes().size(), input.data(), input.size());
    if (ZSTD_isError(decoded)) {
      return std::nullopt;
    }
    const auto accepted = std::min(decoded, destination.size());
    std::copy_n(storage.bytes().data(), accepted, destination.data());
    return accepted;
  }

  static constexpr std::size_t maximum_window_bytes = 8 * 1024 * 1024;
  static constexpr std::size_t frame_descriptor_offset = 4;
  static constexpr unsigned dictionary_flags = 3;
  Memory &allocator_;
  DecoderMemory<Memory> memory_;
  ZSTD_DCtx *state_ = nullptr;
};

template <Allocator Memory>
ZstdDecoder(Memory &memory) -> ZstdDecoder<Memory>;

}
