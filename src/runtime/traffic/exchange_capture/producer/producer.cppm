module;
#include "telar_platform/trace_macro.hpp"

#include "tbc/annotations.hpp"

export module telar.runtime.traffic.exchange_capture.producer;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.runtime.traffic.tap.exchange;
import telar.runtime.traffic.http.content;

import telar.base.text;
import telar.native.brotli;
import telar.native.zlib;
import telar.native.zstd;
import telar.platform.primitives;
import telar.config.runtime;
import telar.base.ds;

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
      BrotliDecoder(BrotliDecoder&&) = delete;
      BrotliDecoder& operator=(BrotliDecoder&&) = delete;

      ds::Option<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept;

    private:
      DecoderMemory<Memory> memory_;
      BrotliDecoderState* state_ = nullptr;
    };

    template <Allocator Memory>
    BrotliDecoder(Memory& memory) -> BrotliDecoder<Memory>;

    template <Allocator Memory>
    [[gnu::noinline]] ds::Option<std::size_t> decodeBrotli(Memory& memory, std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept;

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
      FlateDecoder(FlateDecoder&&) = delete;
      FlateDecoder& operator=(FlateDecoder&&) = delete;

      static constexpr std::size_t history_bytes = 32768;
      static constexpr std::size_t minimum_output_capacity = 2 * history_bytes;

      static std::size_t outputCapacity(std::size_t requested) noexcept;

      ds::Option<std::size_t> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept;

    private:
      enum class BlockKind : std::uint8_t {
        stored,
        fixed,
        dynamic,
        invalid,
      };

      static BlockKind blockKind(std::span<const std::uint8_t> input, std::size_t bit_offset) noexcept;

      // Inflates the stream's body into `output`, a block at a time, until it ends, fills the output
      // or, for stored blocks, holds `requested` bytes.
      ds::Option<std::size_t> inflateBlocks(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept;

      static constexpr std::size_t bits_per_byte = 8;
      static constexpr std::size_t block_kind_bits = 2;
      static constexpr unsigned final_block_flag = 1;
      static constexpr unsigned block_boundary = 128;
      static constexpr unsigned final_block = 64;
      static constexpr unsigned unused_bits_mask = 63;
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
      enum class Kind : std::uint8_t {
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

      static ds::Option<Literals> literals(std::span<const std::uint8_t> bytes) noexcept;

      Kind kind = Kind::raw;
      std::size_t size = 0;

    private:
      static ds::Option<std::uint64_t> read(std::span<const std::uint8_t> bytes, std::size_t count) noexcept;

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
      ZstdDecoder(ZstdDecoder&&) = delete;
      ZstdDecoder& operator=(ZstdDecoder&&) = delete;

      ds::Option<Result> decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, std::size_t limit);

      static constexpr std::size_t minimum_output_capacity = std::size_t{128} * 1024;

      static std::size_t outputCapacity(std::span<const std::uint8_t> input, std::size_t logical_capacity) noexcept;

    private:
      // Where a decode stands: the input left, the output and how much of it is written, and the
      // limit it stops at.
      struct Cursor {
        std::span<const std::uint8_t> input;
        std::span<std::uint8_t> output;
        std::size_t limit = 0;
        std::size_t produced = 0;

        [[nodiscard]] constexpr std::size_t remaining() const noexcept {
          return limit - produced;
        }

        // Storage sized by a declared content size ends before `limit`: a block that reaches the
        // limit there carries more than the frame declares, so it is rejected before any write.
        [[nodiscard]] constexpr bool fits() const noexcept {
          return remaining() <= output.size() - produced;
        }
      };

      // The frame being decoded: its header, the block it is in and where its output starts.
      struct Frame {
        ZSTD_frameHeader header{};
        ZstdBlock block;
        std::size_t start = 0;
        bool known_size = false;
      };

      // What one step of a frame decides: go on, or end the decode with `result`.
      struct Step {
        bool done = false;
        ds::Option<Result> result;
      };

      // Reads the frame's header and starts the context on it; false for a frame telar refuses.
      bool begin(std::span<const std::uint8_t> input, Frame& frame) noexcept;

      // Decodes the next `needed` bytes the context asks for.
      Step advance(Cursor& cursor, Frame& frame, std::size_t needed);

      // Input that ends inside a block: a raw block's bytes up to the limit, else a failure.
      static Step shortInput(const Cursor& cursor, bool raw_block, std::size_t needed) noexcept;

      // Literals with no sequences that pass the limit: the prefix that reaches it.
      Step literalPrefix(const Cursor& cursor, std::size_t needed, std::size_t block_capacity);

      // A raw or RLE block that passes the limit: the bytes up to it.
      static Step uncompressedTail(const Cursor& cursor, ZstdBlock::Kind kind) noexcept;

      Step decompress(Cursor& cursor, const Frame& frame, std::size_t needed) noexcept;

      ds::Option<std::size_t> copyLiteralPrefix(std::span<const std::uint8_t> input, std::span<std::uint8_t> destination, std::size_t block_capacity);

      static constexpr std::size_t maximum_window_bytes = std::size_t{8} * 1024 * 1024;
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

      ds::Option<DecodedBody<Memory>> decodeOne(std::span<const std::uint8_t> input, ContentCoding coding, std::size_t limit);

      // Not inlined: CaptureProducer::decodeBody decodes every captured body with a coding, and only a
      // small flate limit needs this buffer; in its frame it would sit above every other decoder.
      [[gnu::noinline]] ds::Option<DecodedBody<Memory>> decodeSmallFlate(std::span<const std::uint8_t> input, FlateContainer container, std::size_t limit);

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

      Half start(const CaptureStart& context) noexcept;

      bool publish(Half half) noexcept;

      ds::Option<Half> receive();

      ds::Option<Half> tryReceive() noexcept;

      void close() noexcept;

      std::size_t reservedBytes() const noexcept;

      void decodeBody(CaptureHalf& half) noexcept;

      CaptureMetrics metrics() const noexcept;

      static constexpr std::size_t queue_capacity = 256;

    private:
      void countTruncation(CaptureTruncation truncation) noexcept;

      ConcurrentMemory& memory_;
      const ProxyCaptureLimits fixed_limits;
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
