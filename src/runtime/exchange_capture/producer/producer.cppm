module;
#include "telar_platform/trace_macro.hpp"

#include "tbc/annotations.hpp"

export module telar.runtime.exchange_capture.producer;

import std;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;

export import telar.runtime.vocabulary.exchange;
export import telar.runtime.http.content;

import telar.base.diagnostics;
import telar.base.memory.sensitive;
import telar.base.text;
import telar.native.brotli;
import telar.native.zlib;
import telar.native.zstd;
import telar.platform.primitives;

// Interface: exchange_capture/brotli_decoder.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class BrotliDecoder {
    public:
      explicit BrotliDecoder(Memory& memory) noexcept;

      ~BrotliDecoder();

      BrotliDecoder(const BrotliDecoder&) = delete;
      BrotliDecoder& operator=(const BrotliDecoder&) = delete;

      std::optional<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept;

    private:
      DecoderMemory<Memory> memory_;
      BrotliDecoderState* state_ = nullptr;
    };

    template <Allocator Memory>
    BrotliDecoder(Memory& memory) -> BrotliDecoder<Memory>;

    template <Allocator Memory>
    [[gnu::noinline]] std::optional<std::size_t> decodeBrotli(Memory& memory, std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept;

  }
}

// Interface: exchange_capture/flate_decoder.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class FlateDecoder {
    public:
      explicit FlateDecoder(Memory& memory) noexcept;

      ~FlateDecoder();

      FlateDecoder(const FlateDecoder&) = delete;
      FlateDecoder& operator=(const FlateDecoder&) = delete;

      static constexpr std::size_t history_bytes = 32768;
      static constexpr std::size_t minimum_output_capacity = 2 * history_bytes;

      static std::size_t outputCapacity(std::size_t requested) noexcept;

      std::optional<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept;

    private:
      enum class BlockKind {
        stored,
        fixed,
        dynamic,
        invalid,
      };

      static BlockKind blockKind(std::span<const std::uint8_t> input, std::size_t bit_offset) noexcept;

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
    FlateDecoder(Memory& memory) -> FlateDecoder<Memory>;

  }
}

// Interface: exchange_capture/zstd_block.cppm
export {
  namespace telar::runtime {

    struct ZstdBlock {
      enum class Kind {
        raw,
        repeated,
        compressed,
        reserved,
      };

      static ZstdBlock parse(std::span<const std::uint8_t, 3> bytes) noexcept;

      struct Literals {
        std::size_t regenerated_size;
        bool has_sequences;
      };

      static std::optional<Literals> literals(std::span<const std::uint8_t> bytes) noexcept;

      Kind kind = Kind::raw;
      std::size_t size = 0;

    private:
      static std::optional<std::uint64_t> read(std::span<const std::uint8_t> bytes, std::size_t count) noexcept;

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

      explicit ZstdDecoder(Memory& memory) noexcept;

      ~ZstdDecoder();

      ZstdDecoder(const ZstdDecoder&) = delete;
      ZstdDecoder& operator=(const ZstdDecoder&) = delete;

      std::optional<Result> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, std::size_t limit);

      static constexpr std::size_t minimum_output_capacity = 128 * 1024;

      static std::size_t outputCapacity(std::span<const std::uint8_t> input, std::size_t logical_capacity) noexcept;

    private:
      std::optional<std::size_t> copyLiteralPrefix(std::span<const std::uint8_t> input, std::span<std::uint8_t> destination, std::size_t block_capacity);

      static constexpr std::size_t maximum_window_bytes = 8 * 1024 * 1024;
      static constexpr std::size_t frame_descriptor_offset = 4;
      static constexpr unsigned dictionary_flags = 3;
      Memory& allocator_;
      DecoderMemory<Memory> memory_;
      ZSTD_DCtx* state_ = nullptr;
    };

    template <Allocator Memory>
    ZstdDecoder(Memory& memory) -> ZstdDecoder<Memory>;

  }
}

// Interface: exchange_capture/content_decoder.cppm
export {
  namespace telar::runtime {

    class CaptureContentDecoder {
    public:
      explicit CaptureContentDecoder(Memory& memory) noexcept;

      DecodedBody<Memory> decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit);

    private:
      DecodedBody<Memory> raw(std::span<const std::uint8_t> input, std::size_t limit, bool failed);

      std::optional<DecodedBody<Memory>> decodeOne(std::span<const std::uint8_t> input, ContentCoding coding, std::size_t limit);

      std::optional<DecodedBody<Memory>> decodeSmallFlate(std::span<const std::uint8_t> input, FlateContainer container, std::size_t limit);

      Memory& memory_;
    };

  }
}

// Interface: exchange_capture/producer.cppm
export {
  namespace telar::runtime {

    // Proxy threads start and publish halves while the receiver drains them: the limits are fixed once
    // built, and what changes after is atomic or the synchronized channel, so the halves that borrow its
    // quota stay valid whatever is done through it.
    class TBC_SHARED CaptureProducer {
    public:
      using Half = CapturedExchange::Half;

      explicit CaptureProducer(ConcurrentMemory& memory, ProxyCaptureLimits limits);

      Half start(CaptureStart context) noexcept;

      bool publish(Half half) noexcept;

      std::optional<Half> receive();

      std::optional<Half> tryReceive() noexcept;

      void close() noexcept;

      std::size_t reservedBytes() const noexcept;

      void decodeBody(CaptureHalf& half) noexcept;

      CaptureMetrics metrics() const noexcept;

      static constexpr std::size_t queue_capacity = 256;

    private:
      void countTruncation(CaptureTruncation truncation) noexcept;

      ConcurrentMemory& memory_;
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
