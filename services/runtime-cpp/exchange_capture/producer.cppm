module;

#define ZSTD_STATIC_LINKING_ONLY
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstddef>


#include <cstdint>
#include <span>
#include <array>
#include <brotli/decode.h>
#include <optional>


#include <utility>


#include <initializer_list>
#include <zlib.h>


#include <zstd.h>


#include <string_view>
#include "telar_platform/trace.hpp"
#include <stdexcept>


#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <type_traits>

export module telar.runtime.exchange_capture.producer;

export import telar.base.memory;


export import telar.runtime.exchange_capture.exchange;


export import telar.base.text;

// Interface: exchange_capture/decoder_memory.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class DecoderMemory {
public:
  inline explicit DecoderMemory(Memory &memory) noexcept : memory_(memory), blocks_(memory_) {}

  inline static void *allocate(void *context, std::size_t bytes) noexcept {
    return static_cast<DecoderMemory *>(context)->blocks_.allocate(bytes);
  }

  inline static void *allocateArray(void *context, unsigned count, unsigned size) noexcept {
    if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
      return nullptr;
    }
    return allocate(context, static_cast<std::size_t>(count) * size);
  }

  inline static void release(void *context, void *pointer) noexcept {
    static_cast<DecoderMemory *>(context)->blocks_.release(pointer);
  }

private:
  ErasingAllocator<Memory> memory_;
  CAllocationBlocks<ErasingAllocator<Memory>> blocks_;
};

}
}

// Interface: exchange_capture/brotli_decoder.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class BrotliDecoder {
public:
  inline explicit BrotliDecoder(Memory &memory) noexcept : memory_(memory) {
    state_ = BrotliDecoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_);
  }

  inline ~BrotliDecoder() { BrotliDecoderDestroyInstance(state_); }

  BrotliDecoder(const BrotliDecoder &) = delete;
  BrotliDecoder &operator=(const BrotliDecoder &) = delete;

  inline std::optional<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept {
    if (state_ == nullptr) {
      return std::nullopt;
    }
    auto available_input = input.size();
    auto available_output = output.size();
    const auto *next_input = input.data();
    auto *next_output = output.data();
    const auto status = BrotliDecoderDecompressStream(state_, &available_input, &next_input, &available_output, &next_output, nullptr);
    if (status == BROTLI_DECODER_RESULT_SUCCESS || (status == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT && available_output == 0)) {
      return output.size() - available_output;
    }
    return std::nullopt;
  }

private:
  DecoderMemory<Memory> memory_;
  BrotliDecoderState *state_ = nullptr;
};

template <Allocator Memory>
BrotliDecoder(Memory &memory) -> BrotliDecoder<Memory>;

template <Allocator Memory>
[[gnu::noinline]] std::optional<std::size_t> decodeBrotli(Memory &memory, std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept {
  // Isolate scratch storage from the stack frames of the other content decoders.
  constexpr std::size_t decoder_scratch_capacity = 32 * 1024;
  alignas(std::max_align_t) std::array<std::byte, decoder_scratch_capacity> storage;
  BufferAllocator buffered{memory, storage};
  BrotliDecoder decoder{buffered};
  return decoder.decode(input, output);
}

}
}

// Interface: exchange_capture/decoded_body.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct DecodedBody {
  inline explicit DecodedBody(Memory &memory, std::size_t capacity) : storage(memory, capacity) {}

  inline std::span<const std::uint8_t> bytes() const noexcept { return storage.bytes().first(size); }

  SensitiveAllocation<Memory> storage;
  std::size_t size = 0;
  bool decoded = false;
  bool truncated = false;
  bool failed = false;
};

}
}

// Interface: exchange_capture/flate_decoder.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class FlateDecoder {
public:
  inline explicit FlateDecoder(Memory &memory) noexcept : memory_(memory) {
    stream_.zalloc = &DecoderMemory<Memory>::allocateArray;
    stream_.zfree = &DecoderMemory<Memory>::release;
    stream_.opaque = &memory_;
    initialized_ = inflateInit2(&stream_, -MAX_WBITS) == Z_OK;
  }

  inline ~FlateDecoder() {
    if (initialized_) {
      inflateEnd(&stream_);
    }
  }

  FlateDecoder(const FlateDecoder &) = delete;
  FlateDecoder &operator=(const FlateDecoder &) = delete;

  static constexpr std::size_t history_bytes = 32768;
  static constexpr std::size_t minimum_output_capacity = 2 * history_bytes;

  inline static std::size_t outputCapacity(std::size_t requested) noexcept {
    if (requested <= minimum_output_capacity) {
      return minimum_output_capacity;
    }
    const auto remainder = requested % history_bytes;
    const auto padding = remainder == 0 ? 0 : history_bytes - remainder;
    return requested > std::numeric_limits<std::size_t>::max() - padding ? requested : requested + padding;
  }

  inline std::optional<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept {
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

  inline static BlockKind blockKind(std::span<const std::uint8_t> input, std::size_t bit_offset) noexcept {
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
}

// Interface: exchange_capture/zstd_block.cppm
export {
namespace telar::runtime {

struct ZstdBlock {
  enum class Kind { raw,
                    repeated,
                    compressed,
                    reserved };

  inline static ZstdBlock parse(std::span<const std::uint8_t, 3> bytes) noexcept {
    const auto value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
    return {static_cast<Kind>((value >> 1) & 3), static_cast<std::size_t>(value >> 3)};
  }

  struct Literals {
    std::size_t regenerated_size;
    bool has_sequences;
  };

  inline static std::optional<Literals> literals(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes.empty()) {
      return std::nullopt;
    }
    const auto kind = static_cast<unsigned>(bytes[0] & 3);
    const auto format = (bytes[0] >> 2) & 3;
    std::size_t header_size;
    std::size_t payload_size;
    std::size_t regenerated_size;
    if (kind <= repeated_literals) {
      header_size = (format == 0 || format == 2) ? 1 : format == 1 ? 2
                                                                   : 3;
      const auto header = read(bytes, header_size);
      if (!header) {
        return std::nullopt;
      }
      regenerated_size = *header >> (header_size == 1 ? 3 : 4);
      payload_size = kind == repeated_literals ? 1 : regenerated_size;
    } else {
      header_size = format <= 1 ? 3 : format == 2 ? 4
                                                  : 5;
      const auto header = read(bytes, header_size);
      if (!header) {
        return std::nullopt;
      }
      const auto field_bits = format <= 1 ? 10 : format == 2 ? 14
                                                             : 18;
      regenerated_size = (*header >> 4) & ((std::uint64_t{1} << field_bits) - 1);
      payload_size = (*header >> (4 + field_bits)) & ((std::uint64_t{1} << field_bits) - 1);
    }

    if (payload_size >= bytes.size() - header_size) {
      return std::nullopt;
    }
    return Literals{regenerated_size, bytes[header_size + payload_size] != 0};
  }

  Kind kind = Kind::raw;
  std::size_t size = 0;

private:
  inline static std::optional<std::uint64_t> read(std::span<const std::uint8_t> bytes, std::size_t count) noexcept {
    if (bytes.size() < count) {
      return std::nullopt;
    }
    std::uint64_t value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      value |= std::uint64_t{bytes[index]} << (index * 8);
    }
    return value;
  }

  static constexpr unsigned repeated_literals = 1;
};

}
}

// Interface: exchange_capture/zstd_decoder.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ZstdDecoder {
public:
  struct Result {
    std::size_t bytes;
    bool truncated;
  };

  inline explicit ZstdDecoder(Memory &memory) noexcept : allocator_(memory), memory_(memory) {
    state_ = ZSTD_createDCtx_advanced({&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_});
    if (state_ != nullptr) {
      ZSTD_DCtx_setParameter(state_, ZSTD_d_forceIgnoreChecksum, ZSTD_d_ignoreChecksum);
    }
  }

  inline ~ZstdDecoder() { ZSTD_freeDCtx(state_); }

  ZstdDecoder(const ZstdDecoder &) = delete;
  ZstdDecoder &operator=(const ZstdDecoder &) = delete;

  inline std::optional<Result> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, std::size_t limit) {
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

  inline static std::size_t outputCapacity(std::span<const std::uint8_t> input, std::size_t logical_capacity) noexcept {
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
  inline std::optional<std::size_t> copyLiteralPrefix(std::span<const std::uint8_t> input, std::span<std::uint8_t> destination, std::size_t block_capacity) {
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
}

// Interface: exchange_capture/content_decoder.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CaptureContentDecoder {
public:
  inline explicit CaptureContentDecoder(Memory &memory) noexcept : memory_(memory) {}

  inline DecodedBody<Memory> decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) {
    TELAR_TRACE("proxy.decodeCapture");
    if (limit == 0 || limit == std::numeric_limits<std::size_t>::max()) {
      throw std::length_error{"Invalid capture decode limit"};
    }

    std::array<std::string_view, maximum_codings> codings;
    std::size_t count = 0;
    TextFields fields{encoding, ","};
    while (const auto field = fields.next()) {
      const auto coding = trimText(*field, " \t");
      if (coding.empty() || count == codings.size()) {
        return raw(input, limit, true);
      }
      codings[count++] = coding;
    }
    if (count == 1 && asciiEqualIgnoreCase(codings[0], "identity")) {
      auto result = raw(input, limit, false);
      result.decoded = true;
      return result;
    }

    auto current = input;
    std::optional<DecodedBody<Memory>> decoded;
    while (count != 0) {
      const auto coding = codings[--count];
      if (asciiEqualIgnoreCase(coding, "identity")) {
        continue;
      }
      if (!supported(coding)) {
        decoded.reset();
        return raw(input, limit, false);
      }

      std::optional<DecodedBody<Memory>> result;
      try {
        result = decodeOne(current, coding, limit);
      } catch (const std::bad_alloc &) {
      }
      if (!result || (result->truncated && count != 0)) {
        result.reset();
        decoded.reset();
        return raw(input, limit, true);
      }
      decoded = std::move(result);
      current = decoded->bytes();
    }
    return decoded ? std::move(*decoded) : raw(input, limit, false);
  }

private:
  inline DecodedBody<Memory> raw(std::span<const std::uint8_t> input, std::size_t limit, bool failed) {
    const auto accepted = std::min(input.size(), limit);
    DecodedBody<Memory> result{memory_, accepted};
    std::copy_n(input.data(), accepted, result.storage.bytes().data());
    result.size = accepted;
    result.truncated = accepted != input.size();
    result.failed = failed;
    return result;
  }

  inline static bool supported(std::string_view coding) noexcept {
    return asciiEqualIgnoreCase(coding, "gzip") || asciiEqualIgnoreCase(coding, "deflate") || asciiEqualIgnoreCase(coding, "br") || asciiEqualIgnoreCase(coding, "zstd");
  }

  inline std::optional<DecodedBody<Memory>> decodeOne(std::span<const std::uint8_t> input, std::string_view coding, std::size_t limit) {
    const bool zstd = asciiEqualIgnoreCase(coding, "zstd");
    const bool brotli = asciiEqualIgnoreCase(coding, "br");
    const auto container = asciiEqualIgnoreCase(coding, "gzip") ? FlateContainer::gzip : FlateContainer::zlib;
    if (!zstd && !brotli && limit < FlateDecoder<Memory>::minimum_output_capacity) {
      return decodeSmallFlate(input, container, limit);
    }

    const auto capacity = zstd     ? std::max(limit + 1, ZstdDecoder<Memory>::minimum_output_capacity)
                          : brotli ? limit + 1
                                   : FlateDecoder<Memory>::outputCapacity(limit + 1);
    // Complete Zstd frames may need less storage while retaining the same logical validation boundary.
    const auto storage_capacity = zstd ? ZstdDecoder<Memory>::outputCapacity(input, capacity) : capacity;
    DecodedBody<Memory> result{memory_, storage_capacity};
    std::optional<std::size_t> decoded;
    if (zstd) {
      if (const auto progress = ZstdDecoder{memory_}.decode(input, result.storage.bytes(), capacity)) {
        decoded = progress->bytes;
        result.truncated = progress->truncated;
      }
    } else if (brotli) {
      decoded = decodeBrotli(memory_, input, result.storage.bytes());
    } else {
      decoded = FlateDecoder{memory_}.decode(input, result.storage.bytes(), container, limit + 1);
    }
    if (!decoded) {
      return std::nullopt;
    }
    result.size = std::min(*decoded, limit);
    result.truncated = result.truncated || *decoded > limit;
    result.decoded = true;
    return result;
  }

  inline std::optional<DecodedBody<Memory>> decodeSmallFlate(std::span<const std::uint8_t> input, FlateContainer container, std::size_t limit) {
    // Keep the reference's validation boundary beyond the requested prefix before truncating.
    SensitiveBuffer<FlateDecoder<Memory>::minimum_output_capacity> temporary;
    const auto decoded = FlateDecoder{memory_}.decode(input, temporary.bytes(), container, limit + 1);
    if (!decoded) {
      return std::nullopt;
    }

    const auto accepted = std::min(*decoded, limit);
    DecodedBody<Memory> result{memory_, accepted};
    std::copy_n(temporary.bytes().data(), accepted, result.storage.bytes().data());
    result.size = accepted;
    result.truncated = *decoded > limit;
    result.decoded = true;
    return result;
  }

  static constexpr std::size_t maximum_codings = 2;
  Memory &memory_;
};

template <Allocator Memory>
CaptureContentDecoder(Memory &memory) -> CaptureContentDecoder<Memory>;

}
}

// Interface: exchange_capture/producer.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class CaptureProducer {
public:
  using Half = typename CapturedExchange<Memory>::Half;

  inline explicit CaptureProducer(Memory &memory, ProxyCaptureLimits limits)
      : memory_(memory), limits_(limits), quota_(limits.total_bytes) {
    if (!limits.valid()) {
      throw std::invalid_argument{"Invalid proxy capture limits"};
    }
  }

  inline Half start(CaptureStart context) noexcept {
    Half absent{nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory_}};
    if (!limits_.enabled) {
      return absent;
    }
    if (context.host.size() <= CaptureHalf<Memory>::maximum_host_bytes) {
      try {
        auto half = makeOwned<CaptureHalf<Memory>>(memory_, memory_, quota_, limits_, context);
        if (context.side == CaptureSide::request) {
          started_.fetch_add(1, std::memory_order_relaxed);
        }
        return half;
      } catch (const std::bad_alloc &) {
      }
    }
    skipped_.fetch_add(1, std::memory_order_relaxed);
    return absent;
  }

  inline bool publish(Half half) noexcept {
    if (half->head.truncated || half->body.truncated) {
      truncated_.fetch_add(1, std::memory_order_relaxed);
    }
    countTruncation(half->truncation);
    return channel_.publish(std::move(half));
  }

  inline std::optional<Half> receive() { return channel_.receive(); }
  inline std::optional<Half> tryReceive() noexcept { return channel_.tryReceive(); }
  inline void close() noexcept { channel_.close(); }
  inline std::size_t reservedBytes() const noexcept { return quota_.used(); }

  inline void decodeBody(CaptureHalf<Memory> &half) noexcept {
    if (half.encoding().empty() || asciiEqualIgnoreCase(half.encoding(), "identity")) {
      half.body_decoded = true;
      return;
    }

    const auto share_room = half.bodyLimit();
    const auto available = std::min(limits_.part_bytes, share_room);
    if (available == 0) {
      return;
    }

    try {
      CaptureContentDecoder decoder{memory_};
      auto result = decoder.decode(half.body.bytes(), half.encoding(), available);
      if (result.failed) {
        decode_failed_.fetch_add(1, std::memory_order_relaxed);
        return;
      }

      const bool was_truncated = half.body.truncated;
      const auto previous = half.truncation;
      half.body.reset();
      half.append(half.bodyPart(), result.bytes());
      if (result.truncated) {
        if (limits_.part_bytes <= share_room) {
          half.truncation.part = true;
        } else {
          half.truncation.exchange = true;
        }
      }
      half.body.truncated = half.body.truncated || result.truncated || was_truncated;
      half.body_decoded = result.decoded;
      if (!was_truncated && half.body.truncated) {
        truncated_.fetch_add(1, std::memory_order_relaxed);
      }
      countTruncation({half.truncation.part && !previous.part, half.truncation.exchange && !previous.exchange, half.truncation.total && !previous.total});
    } catch (...) {
      decode_failed_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  inline CaptureMetrics metrics() const noexcept {
    const auto queue = channel_.metrics();
    return {
        .started = started_.load(std::memory_order_relaxed),
        .truncated = truncated_.load(std::memory_order_relaxed),
        .truncated_part = truncated_part_.load(std::memory_order_relaxed),
        .truncated_exchange = truncated_exchange_.load(std::memory_order_relaxed),
        .truncated_total = truncated_total_.load(std::memory_order_relaxed),
        .skipped = skipped_.load(std::memory_order_relaxed),
        .decode_failed = decode_failed_.load(std::memory_order_relaxed),
        .dropped_queue = queue.dropped,
        .queued = queue.queued,
        .queue_high_water = queue.high_water,
    };
  }

  static constexpr std::size_t queue_capacity = 256;

private:
  inline void countTruncation(CaptureTruncation truncation) noexcept {
    if (truncation.part) {
      truncated_part_.fetch_add(1, std::memory_order_relaxed);
    }
    if (truncation.exchange) {
      truncated_exchange_.fetch_add(1, std::memory_order_relaxed);
    }
    if (truncation.total) {
      truncated_total_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  Memory &memory_;
  const ProxyCaptureLimits limits_;
  CaptureQuota quota_;
  DropChannel<Half, queue_capacity> channel_;
  std::atomic<std::uint64_t> started_{0};
  std::atomic<std::uint64_t> truncated_{0};
  std::atomic<std::uint64_t> truncated_part_{0};
  std::atomic<std::uint64_t> truncated_exchange_{0};
  std::atomic<std::uint64_t> truncated_total_{0};
  std::atomic<std::uint64_t> skipped_{0};
  std::atomic<std::uint64_t> decode_failed_{0};
};

}
}
