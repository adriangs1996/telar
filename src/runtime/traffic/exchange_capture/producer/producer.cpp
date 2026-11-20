module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.traffic.exchange_capture.producer;

import telar.native.brotli;
import telar.native.zlib;
import telar.native.zstd;
import telar.base.memory.sensitive;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    constexpr unsigned byte_bits = 8;

    // A raw deflate stream that allocates through `memory`.
    template <Allocator Memory>
    z_stream flateStream(DecoderMemory<Memory>& memory) noexcept {
      z_stream stream{};

      stream.zalloc = &DecoderMemory<Memory>::allocateArray;
      stream.zfree = &DecoderMemory<Memory>::release;
      stream.opaque = &memory;
      return stream;
    }

    // A literals section header (RFC 8878 3.1.1.3.1.1) starts with two bits of block type and two
    // of size format, then the sizes: one of 5, 12 or 20 bits for raw and RLE literals, by format,
    // and two of 10, 14 or 18 bits each for compressed ones.
    constexpr unsigned two_bits = 3;
    constexpr unsigned format_shift = 2;
    constexpr unsigned short_size_shift = 3;
    constexpr unsigned size_shift = 4;

    struct CompressedLiterals {
      std::size_t header_bytes = 0;
      unsigned size_bits = 0;
    };

    constexpr ds::Array<std::size_t, 4> raw_literals_header_bytes{1, 2, 1, 3};
    constexpr ds::Array<CompressedLiterals, 4> compressed_literals{
        {
            {.header_bytes = 3, .size_bits = 10},
            {.header_bytes = 3, .size_bits = 10},
            {.header_bytes = 4, .size_bits = 14},
            {.header_bytes = 5, .size_bits = 18},
        },
    };

  }

  template <Allocator Memory>
  BrotliDecoder<Memory>::BrotliDecoder(Memory& memory) noexcept
      : memory_(memory),
        state_(BrotliDecoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_)) {}

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
    constexpr std::size_t decoder_scratch_capacity = std::size_t{32} * 1024;
    alignas(std::max_align_t) ds::Array<std::byte, decoder_scratch_capacity> storage; // NOLINT(cppcoreguidelines-pro-type-member-init): scratch for every brotli body, which the decoder reads only after it allocates it
    BufferAllocator buffered{memory, storage.viewMut()};
    BrotliDecoder decoder{buffered};

    return decoder.decode(input, output);
  }

  template <Allocator Memory>
  FlateDecoder<Memory>::FlateDecoder(Memory& memory) noexcept
      : memory_(memory),
        stream_(flateStream(memory_)),
        initialized_(inflateInit2(&stream_, -MAX_WBITS) == Z_OK) {}

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
    const auto produced = inflateBlocks(input, output, container, requested);

    stream_.next_in = nullptr;
    stream_.next_out = nullptr;
    return produced;
  }

  template <Allocator Memory>
  ds::Option<std::size_t> FlateDecoder<Memory>::inflateBlocks(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, FlateContainer container, std::size_t requested) noexcept {
    stream_.next_in = const_cast<Bytef*>(input.data()); // NOLINT(cppcoreguidelines-pro-type-const-cast): zlib's next_in is non-const unless ZLIB_CONST, and inflate only reads through it
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

      const auto data_type = static_cast<unsigned>(stream_.data_type);
      if ((data_type & block_boundary) != 0 && (data_type & final_block) == 0) {
        const auto bit_offset = (stream_.total_in * bits_per_byte) - (data_type & unused_bits_mask);

        kind = blockKind(input, bit_offset);
      }
    }
  }

  template <Allocator Memory>
  auto FlateDecoder<Memory>::blockKind(std::span<const std::uint8_t> input, std::size_t bit_offset) noexcept -> BlockKind {
    unsigned kind = 0;

    for (std::size_t bit = 0; bit < block_kind_bits; ++bit) {
      const auto position = bit_offset + 1 + bit;
      if (position / bits_per_byte >= input.size()) {
        return BlockKind::invalid;
      }

      const unsigned byte = input[position / bits_per_byte];

      kind |= ((byte >> (position % bits_per_byte)) & 1U) << bit;
    }

    return static_cast<BlockKind>(kind);
  }

  ZstdBlock ZstdBlock::parse(std::span<const std::uint8_t, 3> bytes) noexcept {
    // Little-endian: a last-block bit, two bits of block type, then the size.
    constexpr unsigned block_size_shift = 3;
    const auto value = static_cast<unsigned>(bytes[0]) | (static_cast<unsigned>(bytes[1]) << byte_bits) | (static_cast<unsigned>(bytes[2]) << (2 * byte_bits));

    return {.kind = static_cast<Kind>((value >> 1U) & two_bits), .size = static_cast<std::size_t>(value >> block_size_shift)};
  }

  auto ZstdBlock::literals(std::span<const std::uint8_t> bytes) noexcept -> ds::Option<Literals> {
    if (bytes.empty()) {
      return ds::none;
    }

    const unsigned first = bytes[0];
    const auto kind = first & two_bits;
    const auto format = (first >> format_shift) & two_bits;
    const bool raw = kind <= repeated_literals;
    const auto header_size = raw ? raw_literals_header_bytes[format] : compressed_literals[format].header_bytes;
    const auto header = read(bytes, header_size);
    if (!header) {
      return ds::none;
    }

    std::size_t regenerated_size = 0;
    std::size_t payload_size = 0;

    if (raw) {
      regenerated_size = *header >> (header_size == 1 ? short_size_shift : size_shift);
      payload_size = kind == repeated_literals ? 1 : regenerated_size;
    } else {
      const auto field_bits = compressed_literals[format].size_bits;
      const auto field_mask = (std::uint64_t{1} << field_bits) - 1;

      regenerated_size = (*header >> size_shift) & field_mask;
      payload_size = (*header >> (size_shift + field_bits)) & field_mask;
    }

    if (payload_size >= bytes.size() - header_size) {
      return ds::none;
    }

    return Literals{.regenerated_size = regenerated_size, .has_sequences = bytes[header_size + payload_size] != 0};
  }

  ds::Option<std::uint64_t> ZstdBlock::read(std::span<const std::uint8_t> bytes, std::size_t count) noexcept {
    if (bytes.size() < count) {
      return ds::none;
    }

    std::uint64_t value = 0;

    for (std::size_t index = 0; index < count; ++index) {
      value |= std::uint64_t{bytes[index]} << (index * byte_bits);
    }

    return value;
  }

  template <Allocator Memory>
  ZstdDecoder<Memory>::ZstdDecoder(Memory& memory) noexcept
      : allocator_(memory),
        memory_(memory),
        state_(ZSTD_createDCtx_advanced({&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory_})) {
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

    Cursor cursor{.input = input, .output = output, .limit = limit};

    while (!cursor.input.empty()) {
      Frame frame{.start = cursor.produced};
      if (!begin(cursor.input, frame)) {
        return ds::none;
      }

      while (const auto needed = ZSTD_nextSrcSizeToDecompress(state_)) {
        auto step = advance(cursor, frame, needed);
        if (step.done) {
          return step.result;
        }
      }

      if (frame.known_size && cursor.produced - frame.start != frame.header.frameContentSize) {
        return ds::none;
      }
    }

    return Result{cursor.produced, false};
  }

  template <Allocator Memory>
  bool ZstdDecoder<Memory>::begin(std::span<const std::uint8_t> input, Frame& frame) noexcept {
    const auto header = ZSTD_getFrameHeader(&frame.header, input.data(), input.size());
    if (header != 0 || frame.header.windowSize > maximum_window_bytes || (frame.header.frameType == ZSTD_frame && (input[frame_descriptor_offset] & dictionary_flags) != 0)) {
      return false;
    }

    if (ZSTD_isError(ZSTD_decompressBegin(state_)) != 0U) {
      return false;
    }

    frame.known_size = frame.header.frameType == ZSTD_frame && frame.header.frameContentSize != ZSTD_CONTENTSIZE_UNKNOWN;
    return true;
  }

  template <Allocator Memory>
  auto ZstdDecoder<Memory>::advance(Cursor& cursor, Frame& frame, std::size_t needed) -> Step {
    const auto kind = ZSTD_nextInputType(state_);
    const bool block_data = kind == ZSTDnit_block || kind == ZSTDnit_lastBlock;
    const auto remaining = cursor.remaining();

    if (needed > cursor.input.size()) {
      return shortInput(cursor, block_data && frame.block.kind == ZstdBlock::Kind::raw, needed);
    }

    bool requires_block_capacity = false;

    if (kind == ZSTDnit_blockHeader) {
      frame.block = ZstdBlock::parse(cursor.input.template first<3>());
      if (frame.block.size > frame.header.blockSizeMax) {
        return Step{.done = true};
      }
    } else if (block_data && frame.block.kind == ZstdBlock::Kind::compressed) {
      const auto literals = ZstdBlock::literals(cursor.input.first(needed));
      if (!literals) {
        return Step{.done = true};
      }

      requires_block_capacity = literals->has_sequences;
      if (!literals->has_sequences && literals->regenerated_size > remaining) {
        return literalPrefix(cursor, needed, frame.header.blockSizeMax);
      }
    }

    // A full capture stops at the writer boundary before later frame validation.
    if (block_data && frame.block.kind != ZstdBlock::Kind::compressed && frame.block.size > remaining) {
      return uncompressedTail(cursor, frame.block.kind);
    }

    // The reference reserves a complete output block before expanding sequences.
    if (requires_block_capacity && remaining < frame.header.blockSizeMax) {
      return Step{.done = true, .result = Result{cursor.produced, true}};
    }

    return decompress(cursor, frame, needed);
  }

  template <Allocator Memory>
  auto ZstdDecoder<Memory>::shortInput(const Cursor& cursor, bool raw_block, std::size_t needed) noexcept -> Step {
    const auto remaining = cursor.remaining();
    if (raw_block && cursor.input.size() >= remaining && needed > remaining && cursor.fits()) {
      std::ranges::copy(cursor.input.first(remaining), cursor.output.subspan(cursor.produced).begin());
      return Step{.done = true, .result = Result{cursor.limit, true}};
    }

    return Step{.done = true};
  }

  template <Allocator Memory>
  auto ZstdDecoder<Memory>::literalPrefix(const Cursor& cursor, std::size_t needed, std::size_t block_capacity) -> Step {
    if (!cursor.fits()) {
      return Step{.done = true};
    }

    const auto copied = copyLiteralPrefix(cursor.input.first(needed), cursor.output.subspan(cursor.produced, cursor.remaining()), block_capacity);
    if (!copied) {
      return Step{.done = true};
    }

    return Step{.done = true, .result = Result{cursor.produced + *copied, true}};
  }

  template <Allocator Memory>
  auto ZstdDecoder<Memory>::uncompressedTail(const Cursor& cursor, ZstdBlock::Kind kind) noexcept -> Step {
    if (!cursor.fits()) {
      return Step{.done = true};
    }

    const auto remaining = cursor.remaining();
    const auto destination = cursor.output.subspan(cursor.produced, remaining);

    if (kind == ZstdBlock::Kind::raw) {
      std::ranges::copy(cursor.input.first(remaining), destination.begin());
    } else if (kind == ZstdBlock::Kind::repeated) {
      std::ranges::fill(destination, cursor.input.front());
    } else {
      return Step{.done = true};
    }

    return Step{.done = true, .result = Result{cursor.limit, true}};
  }

  template <Allocator Memory>
  auto ZstdDecoder<Memory>::decompress(Cursor& cursor, const Frame& frame, std::size_t needed) noexcept -> Step {
    const auto destination = cursor.output.subspan(cursor.produced);
    const auto decoded = ZSTD_decompressContinue(state_, destination.data(), destination.size(), cursor.input.data(), needed);
    if (ZSTD_isError(decoded) != 0U) {
      return Step{.done = true};
    }

    if (decoded > cursor.remaining()) {
      return Step{.done = true, .result = Result{cursor.limit, true}};
    }

    cursor.produced += decoded;
    if (frame.known_size && cursor.produced - frame.start > frame.header.frameContentSize) {
      return Step{.done = true};
    }

    cursor.input = cursor.input.subspan(needed);
    return Step{};
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
      } catch (const std::bad_alloc&) { // NOLINT(bugprone-empty-catch): a body without memory to decode is kept raw, as one that fails to decode
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

    const auto capacity = [&] {
      if (zstd) {
        return std::max(limit + 1, ZstdDecoder<Memory>::minimum_output_capacity);
      }

      return brotli ? limit + 1 : FlateDecoder<Memory>::outputCapacity(limit + 1);
    }();

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
        fixed_limits(limits),
        quota_(limits.total_bytes) {
    if (!limits.valid()) {
      throw std::invalid_argument{"Invalid proxy capture limits"};
    }
  }

  auto CaptureProducer::start(const CaptureStart& context) noexcept -> Half {
    if (!fixed_limits.enabled) {
      return Half{};
    }

    if (!context.host.oversized()) {
      try {
        auto half = ds::makeBox<CaptureHalf>(memory_, memory_, quota_, fixed_limits, context);

        if (context.side == CaptureSide::request) {
          started_.fetch_add(1, std::memory_order_relaxed);
        }

        return half;
      } catch (const std::bad_alloc&) { // NOLINT(bugprone-empty-catch): a half without memory is skipped and counted, as an oversized one
      }
    }

    skipped_.fetch_add(1, std::memory_order_relaxed);
    return Half{};
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
    const auto available = std::min(fixed_limits.part_bytes, share_room);
    if (available == 0) {
      return;
    }

    try {
      CaptureContentDecoder decoder{memory_};
      const auto result = decoder.decode(half.body.bytes(), half.encoding(), available);
      if (result.failed) {
        decode_failed_.fetch_add(1, std::memory_order_relaxed);
        return;
      }

      const bool was_truncated = half.body.truncated;
      const auto previous = half.truncation;

      half.body.reset();
      half.append(half.bodyPart(), result.bytes());
      if (result.truncated) {
        if (fixed_limits.part_bytes <= share_room) {
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

      countTruncation({.part = half.truncation.part && !previous.part, .exchange = half.truncation.exchange && !previous.exchange, .total = half.truncation.total && !previous.total});
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
