module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.exchange_capture.producer;

import telar.native.brotli;
import telar.native.zlib;
import telar.native.zstd;
import telar.base.memory.sensitive;
import telar.base.ds;

namespace telar::runtime {

  template <Allocator Memory>
  BrotliDecoder<Memory>::BrotliDecoder(Memory& memory) noexcept
      : memory_(memory) {
    state_ = BrotliDecoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_);
  }

  template <Allocator Memory>
  BrotliDecoder<Memory>::~BrotliDecoder() {
    BrotliDecoderDestroyInstance(state_);
  }

  template <Allocator Memory>
  ds::Option<std::size_t> BrotliDecoder<Memory>::decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept {
    if (state_ == nullptr) {
      return ds::none;
    }

    auto available_input = input.size();
    auto available_output = output.size();
    const auto* next_input = input.data();
    auto* next_output = output.data();
    const auto status = BrotliDecoderDecompressStream(state_, &available_input, &next_input, &available_output, &next_output, nullptr);
    if (status == BROTLI_DECODER_RESULT_SUCCESS || (status == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT && available_output == 0)) {
      return output.size() - available_output;
    }

    return ds::none;
  }

  template <Allocator Memory>
  [[gnu::noinline]] ds::Option<std::size_t> decodeBrotli(Memory& memory, std::span<const std::uint8_t> input, std::span<std::uint8_t> output) noexcept {
    // Isolate scratch storage from the stack frames of the other content decoders.
    constexpr std::size_t decoder_scratch_capacity = 32 * 1024;
    alignas(std::max_align_t) std::array<std::byte, decoder_scratch_capacity> storage;
    BufferAllocator buffered{memory, storage};
    BrotliDecoder decoder{buffered};

    return decoder.decode(input, output);
  }

  template <Allocator Memory>
  FlateDecoder<Memory>::FlateDecoder(Memory& memory) noexcept
      : memory_(memory) {
    stream_.zalloc = &DecoderMemory<Memory>::allocateArray;
    stream_.zfree = &DecoderMemory<Memory>::release;
    stream_.opaque = &memory_;
    initialized_ = inflateInit2(&stream_, -MAX_WBITS) == Z_OK;
  }

  template <Allocator Memory>
  FlateDecoder<Memory>::~FlateDecoder() {
    if (initialized_) {
      inflateEnd(&stream_);
    }
  }

  template <Allocator Memory>
  std::size_t FlateDecoder<Memory>::outputCapacity(std::size_t requested) noexcept {
    if (requested <= minimum_output_capacity) {
      return minimum_output_capacity;
    }

    const auto remainder = requested % history_bytes;
    const auto padding = remainder == 0 ? 0 : history_bytes - remainder;

    return requested > std::numeric_limits<std::size_t>::max() - padding ? requested : requested + padding;
  }

  template <Allocator Memory>
  ds::Option<std::size_t> FlateDecoder<Memory>::decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept {
    const auto offset = FlateEnvelope::bodyOffset(input, container);
    if (!initialized_ || !offset || input.size() > std::numeric_limits<uInt>::max() || output.size() > std::numeric_limits<uInt>::max()) {
      return ds::none;
    }

    // Capture in the reference consumes these checksums without validating them.
    // Parsing the envelope separately preserves that best-effort observation contract.
    input = input.subspan(*offset);
    // zlib holds the caller's buffers only for this call, so the stream lets go of them before it returns.
    const auto produced = [&]() noexcept -> ds::Option<std::size_t> {
      stream_.next_in = const_cast<Bytef*>(input.data());
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
          return ds::none;
        }

        const auto written = output.size() - stream_.avail_out;
        if (stream_.avail_out == 0 || (kind == BlockKind::stored && written >= requested)) {
          return written;
        }

        if (status == Z_STREAM_END) {
          return stream_.avail_in >= FlateEnvelope::footerSize(container) ? ds::Option{written} : ds::none;
        }

        if (previous_input == stream_.total_in && previous_output == stream_.total_out) {
          return ds::none;
        }

        if ((stream_.data_type & block_boundary) != 0 && (stream_.data_type & final_block) == 0) {
          const auto bit_offset = stream_.total_in * bits_per_byte - (stream_.data_type & unused_bits_mask);

          kind = blockKind(input, bit_offset);
        }
      }
    }();

    stream_.next_in = nullptr;
    stream_.next_out = nullptr;
    return produced;
  }

  template <Allocator Memory>
  auto FlateDecoder<Memory>::blockKind(std::span<const std::uint8_t> input, std::size_t bit_offset) noexcept -> BlockKind {
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

  ZstdBlock ZstdBlock::parse(std::span<const std::uint8_t, 3> bytes) noexcept {
    const auto value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);

    return {static_cast<Kind>((value >> 1) & 3), static_cast<std::size_t>(value >> 3)};
  }

  auto ZstdBlock::literals(std::span<const std::uint8_t> bytes) noexcept -> ds::Option<Literals> {
    if (bytes.empty()) {
      return ds::none;
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
        return ds::none;
      }

      regenerated_size = *header >> (header_size == 1 ? 3 : 4);
      payload_size = kind == repeated_literals ? 1 : regenerated_size;
    } else {
      header_size = format <= 1 ? 3 : format == 2 ? 4
                                                  : 5;
      const auto header = read(bytes, header_size);
      if (!header) {
        return ds::none;
      }

      const auto field_bits = format <= 1 ? 10 : format == 2 ? 14
                                                             : 18;

      regenerated_size = (*header >> 4) & ((std::uint64_t{1} << field_bits) - 1);
      payload_size = (*header >> (4 + field_bits)) & ((std::uint64_t{1} << field_bits) - 1);
    }

    if (payload_size >= bytes.size() - header_size) {
      return ds::none;
    }

    return Literals{regenerated_size, bytes[header_size + payload_size] != 0};
  }

  ds::Option<std::uint64_t> ZstdBlock::read(std::span<const std::uint8_t> bytes, std::size_t count) noexcept {
    if (bytes.size() < count) {
      return ds::none;
    }

    std::uint64_t value = 0;

    for (std::size_t index = 0; index < count; ++index) {
      value |= std::uint64_t{bytes[index]} << (index * 8);
    }

    return value;
  }

  template <Allocator Memory>
  ZstdDecoder<Memory>::ZstdDecoder(Memory& memory) noexcept
      : allocator_(memory),
        memory_(memory) {
    state_ = ZSTD_createDCtx_advanced({&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_});
    if (state_ != nullptr) {
      ZSTD_DCtx_setParameter(state_, ZSTD_d_forceIgnoreChecksum, ZSTD_d_ignoreChecksum);
    }
  }

  template <Allocator Memory>
  ZstdDecoder<Memory>::~ZstdDecoder() {
    ZSTD_freeDCtx(state_);
  }

  template <Allocator Memory>
  auto ZstdDecoder<Memory>::decode(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, std::size_t limit) -> ds::Option<Result> {
    if (state_ == nullptr) {
      return ds::none;
    }

    std::size_t produced = 0;

    while (!input.empty()) {
      ZSTD_frameHeader frame{};
      const auto header = ZSTD_getFrameHeader(&frame, input.data(), input.size());
      if (header != 0 || frame.windowSize > maximum_window_bytes || (frame.frameType == ZSTD_frame && (input[frame_descriptor_offset] & dictionary_flags) != 0)) {
        return ds::none;
      }

      if (ZSTD_isError(ZSTD_decompressBegin(state_))) {
        return ds::none;
      }

      ZstdBlock block;
      const auto frame_start = produced;
      const bool known_size = frame.frameType == ZSTD_frame && frame.frameContentSize != ZSTD_CONTENTSIZE_UNKNOWN;

      while (const auto needed = ZSTD_nextSrcSizeToDecompress(state_)) {
        const auto kind = ZSTD_nextInputType(state_);
        const auto remaining = limit - produced;
        // Storage sized by a declared content size ends before `limit`: a block that reaches the limit
        // there carries more than the frame declares, so it is rejected before any write.
        const bool fits = remaining <= output.size() - produced;

        if (needed > input.size()) {
          if ((kind == ZSTDnit_block || kind == ZSTDnit_lastBlock) && block.kind == ZstdBlock::Kind::raw && input.size() >= remaining && needed > remaining && fits) {
            std::copy_n(input.data(), remaining, output.data() + produced);
            return Result{limit, true};
          }

          return ds::none;
        }

        bool requires_block_capacity = false;

        if (kind == ZSTDnit_blockHeader) {
          block = ZstdBlock::parse(input.first<3>());
          if (block.size > frame.blockSizeMax) {
            return ds::none;
          }
        } else if ((kind == ZSTDnit_block || kind == ZSTDnit_lastBlock) && block.kind == ZstdBlock::Kind::compressed) {
          const auto literals = ZstdBlock::literals(input.first(needed));
          if (!literals) {
            return ds::none;
          }

          requires_block_capacity = literals->has_sequences;
          if (!literals->has_sequences && literals->regenerated_size > remaining) {
            if (!fits) {
              return ds::none;
            }

            const auto copied = copyLiteralPrefix(input.first(needed), output.subspan(produced, remaining), frame.blockSizeMax);

            return copied ? ds::Option{Result{produced + *copied, true}} : ds::none;
          }
        }

        // A full capture stops at the writer boundary before later frame validation.
        if ((kind == ZSTDnit_block || kind == ZSTDnit_lastBlock) && block.kind != ZstdBlock::Kind::compressed && block.size > remaining) {
          if (!fits) {
            return ds::none;
          }

          if (block.kind == ZstdBlock::Kind::raw) {
            std::copy_n(input.data(), remaining, output.data() + produced);
          } else if (block.kind == ZstdBlock::Kind::repeated) {
            std::fill_n(output.data() + produced, remaining, input.front());
          } else {
            return ds::none;
          }

          return Result{limit, true};
        }

        // The reference reserves a complete output block before expanding sequences.
        if (requires_block_capacity && remaining < frame.blockSizeMax) {
          return Result{produced, true};
        }

        const auto decoded = ZSTD_decompressContinue(state_, output.data() + produced, output.size() - produced, input.data(), needed);
        if (ZSTD_isError(decoded)) {
          return ds::none;
        }

        if (decoded > remaining) {
          return Result{limit, true};
        }

        produced += decoded;
        if (known_size && produced - frame_start > frame.frameContentSize) {
          return ds::none;
        }

        input = input.subspan(needed);
      }

      if (known_size && produced - frame_start != frame.frameContentSize) {
        return ds::none;
      }
    }

    return Result{produced, false};
  }

  template <Allocator Memory>
  std::size_t ZstdDecoder<Memory>::outputCapacity(std::span<const std::uint8_t> input, std::size_t logical_capacity) noexcept {
    if (logical_capacity > minimum_output_capacity) {
      return logical_capacity;
    }

    const auto content_size = ZSTD_getFrameContentSize(input.data(), input.size());
    if (content_size >= logical_capacity || ZSTD_findFrameCompressedSize(input.data(), input.size()) != input.size()) {
      return logical_capacity;
    }

    return std::max<std::size_t>(1, content_size);
  }

  template <Allocator Memory>
  ds::Option<std::size_t> ZstdDecoder<Memory>::copyLiteralPrefix(std::span<const std::uint8_t> input, std::span<std::uint8_t> destination, std::size_t block_capacity) {
    SensitiveAllocation storage{allocator_, block_capacity};
    const auto decoded = ZSTD_decompressContinue(state_, storage.bytesMut().data(), storage.bytesMut().size(), input.data(), input.size());
    if (ZSTD_isError(decoded)) {
      return ds::none;
    }

    const auto accepted = std::min(decoded, destination.size());

    std::copy_n(storage.bytes().data(), accepted, destination.data());
    return accepted;
  }

  CaptureContentDecoder::CaptureContentDecoder(Memory& memory) noexcept
      : memory_(memory) {}

  DecodedBody<Memory> CaptureContentDecoder::decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) {
    TELAR_TRACE("proxy.decodeCapture");
    if (limit == 0 || limit == std::numeric_limits<std::size_t>::max()) {
      throw std::length_error{"Invalid capture decode limit"};
    }

    const auto parsed = ContentCodings::parse(encoding);
    if (parsed.failure != ContentCodings::Failure::none) {
      return raw(input, limit, true);
    }

    auto count = parsed.count;
    if (count == 1 && parsed.codings[0] == ContentCoding::identity) {
      auto result = raw(input, limit, false);

      result.decoded = true;
      return result;
    }

    auto current = input;
    ds::Option<DecodedBody<Memory>> decoded;

    while (count != 0) {
      const auto coding = parsed.codings[--count];
      if (coding == ContentCoding::identity) {
        continue;
      }

      if (coding == ContentCoding::unknown) {
        decoded.reset();
        return raw(input, limit, false);
      }

      ds::Option<DecodedBody<Memory>> result;

      try {
        result = decodeOne(current, coding, limit);
      } catch (const std::bad_alloc&) {
      }

      if (!result || (result->truncated && count != 0)) {
        result.reset();
        decoded.reset();
        return raw(input, limit, true);
      }

      decoded = std::move(result);
      current = decoded->bytes();
    }

    return decoded ? std::move(decoded.getMut()) : raw(input, limit, false);
  }

  DecodedBody<Memory> CaptureContentDecoder::raw(std::span<const std::uint8_t> input, std::size_t limit, bool failed) {
    const auto accepted = std::min(input.size(), limit);
    DecodedBody<Memory> result{memory_, accepted};

    std::copy_n(input.data(), accepted, result.storage.bytesMut().data());
    result.size = accepted;
    result.truncated = accepted != input.size();
    result.failed = failed;
    return result;
  }

  ds::Option<DecodedBody<Memory>> CaptureContentDecoder::decodeOne(std::span<const std::uint8_t> input, ContentCoding coding, std::size_t limit) {
    const bool zstd = coding == ContentCoding::zstd;
    const bool brotli = coding == ContentCoding::brotli;
    const auto container = coding == ContentCoding::gzip ? FlateContainer::gzip : FlateContainer::zlib;

    if (!zstd && !brotli && limit < FlateDecoder<Memory>::minimum_output_capacity) {
      return decodeSmallFlate(input, container, limit);
    }

    const auto capacity = zstd     ? std::max(limit + 1, ZstdDecoder<Memory>::minimum_output_capacity)
                          : brotli ? limit + 1
                                   : FlateDecoder<Memory>::outputCapacity(limit + 1);
    // Complete Zstd frames may need less storage while retaining the same logical validation boundary.
    const auto storage_capacity = zstd ? ZstdDecoder<Memory>::outputCapacity(input, capacity) : capacity;
    DecodedBody<Memory> result{memory_, storage_capacity};
    ds::Option<std::size_t> decoded;

    if (zstd) {
      if (const auto progress = ZstdDecoder{memory_}.decode(input, result.storage.bytesMut(), capacity)) {
        decoded = progress->bytes;
        result.truncated = progress->truncated;
      }
    } else if (brotli) {
      decoded = decodeBrotli(memory_, input, result.storage.bytesMut());
    } else {
      decoded = FlateDecoder{memory_}.decode(input, result.storage.bytesMut(), container, limit + 1);
    }

    if (!decoded) {
      return ds::none;
    }

    result.size = std::min(*decoded, limit);
    result.truncated = result.truncated || *decoded > limit;
    result.decoded = true;
    return result;
  }

  ds::Option<DecodedBody<Memory>> CaptureContentDecoder::decodeSmallFlate(std::span<const std::uint8_t> input, FlateContainer container, std::size_t limit) {
    // Keep the reference's validation boundary beyond the requested prefix before truncating.
    SensitiveBuffer<FlateDecoder<Memory>::minimum_output_capacity> temporary;
    const auto decoded = FlateDecoder{memory_}.decode(input, temporary.bytes(), container, limit + 1);
    if (!decoded) {
      return ds::none;
    }

    const auto accepted = std::min(*decoded, limit);
    DecodedBody<Memory> result{memory_, accepted};

    std::copy_n(temporary.bytes().data(), accepted, result.storage.bytesMut().data());
    result.size = accepted;
    result.truncated = *decoded > limit;
    result.decoded = true;
    return result;
  }

  CaptureProducer::CaptureProducer(ConcurrentMemory& memory, ProxyCaptureLimits limits)
      : memory_(memory),
        limits_(limits),
        quota_(limits.total_bytes) {
    if (!limits.valid()) {
      throw std::invalid_argument{"Invalid proxy capture limits"};
    }
  }

  auto CaptureProducer::start(CaptureStart context) noexcept -> Half {
    Half absent{nullptr, AllocationDeleter<CaptureHalf, ConcurrentMemory>{memory_}};

    if (!limits_.enabled) {
      return absent;
    }

    if (!context.host.oversized()) {
      try {
        auto half = makeOwned<CaptureHalf>(memory_, memory_, quota_, limits_, context);

        if (context.side == CaptureSide::request) {
          started_.fetch_add(1, std::memory_order_relaxed);
        }

        return half;
      } catch (const std::bad_alloc&) {
      }
    }

    skipped_.fetch_add(1, std::memory_order_relaxed);
    return absent;
  }

  bool CaptureProducer::publish(Half half) noexcept {
    if (half->head.truncated || half->body.truncated) {
      truncated_.fetch_add(1, std::memory_order_relaxed);
    }

    countTruncation(half->truncation);
    return channel_.publish(std::move(half));
  }

  auto CaptureProducer::receive() -> ds::Option<Half> {
    return channel_.receive();
  }

  auto CaptureProducer::tryReceive() noexcept -> ds::Option<Half> {
    return channel_.tryReceive();
  }

  void CaptureProducer::close() noexcept {
    channel_.close();
  }

  std::size_t CaptureProducer::reservedBytes() const noexcept {
    return quota_.used();
  }

  void CaptureProducer::decodeBody(CaptureHalf& half) noexcept {
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

  CaptureMetrics CaptureProducer::metrics() const noexcept {
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

  void CaptureProducer::countTruncation(CaptureTruncation truncation) noexcept {
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

}
