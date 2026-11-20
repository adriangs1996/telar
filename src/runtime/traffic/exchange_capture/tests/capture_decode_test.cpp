#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <zlib.h>
#include <zstd.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.platform.primitives;
import telar.testing;
import telar.testing.test_memory;
import telar.testing.erasure_checking_allocator;
import telar.runtime.traffic.exchange_capture.producer;
import telar.config.runtime;
import telar.runtime.traffic.tap.exchange;
import telar.runtime.traffic.http.message;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::vector<std::uint8_t> decodeHexadecimal(std::string_view text) {
    std::vector<std::uint8_t> result;

    for (std::size_t offset = 0; offset < text.size(); offset += 2) {
      unsigned byte = 0;
      const auto parsed = std::from_chars(text.data() + offset, text.data() + offset + 2, byte, 16);

      check(parsed.ec == std::errc{} && parsed.ptr == text.data() + offset + 2);
      result.push_back(static_cast<std::uint8_t>(byte));
    }

    return result;
  }

  void testCaptureDecoding() {
    struct Fixture {
      std::string_view coding;
      std::string_view hexadecimal;
    };

    const ds::Array fixtures{
        Fixture{"gzip", "1f8b08000000000002ff4b4e2c28292d4a5548ca4fa904009b1d16120c000000"},
        Fixture{"deflate", "789c4b4e2c28292d4a5548ca4fa904001f2904c3"},
        Fixture{"br", "8b05806361707475726520626f647903"},
        Fixture{"zstd", "28b52ffd200c6100006361707475726520626f6479"},
    };

    constexpr std::string_view plaintext = "capture body";
    ErasureCheckingAllocator system;

    for (const auto& fixture : fixtures) {
      const auto input = decodeHexadecimal(fixture.hexadecimal);

      for (const std::size_t limit : {1, 11, 12, 13, 1024}) {
        BudgetAllocator memory{system, 2 * 1024 * 1024};
        MemoryAdapter adapter{memory};

        {
          CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};
          const auto body = decoder.decode(input, fixture.coding, limit);

          check(body.decoded && !body.failed && body.truncated == (limit < plaintext.size()));
          check(std::string_view{reinterpret_cast<const char*>(body.bytes().data()), body.size} == plaintext.substr(0, limit));
        }

        check(memory.liveBytes() == 0);
      }

      for (const std::size_t budget : {0, 12, 1024, 65536, 131072}) {
        BudgetAllocator memory{system, budget};
        MemoryAdapter adapter{memory};

        {
          CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};

          try {
            const auto body = decoder.decode(input, fixture.coding, 1024);

            check(body.decoded || body.failed);
          } catch (const std::bad_alloc&) {
          }
        }

        check(memory.liveBytes() == 0);
      }
    }

    BudgetAllocator memory{system, 1024};

    {
      auto first = SensitiveAllocation{memory, 127};
      auto second = SensitiveAllocation{memory, 63};

      std::fill(first.bytesMut().begin(), first.bytesMut().end(), 72);
      second = std::move(first);
      check(first.bytes().empty() && second.bytes().size() == 127 && memory.liveBytes() == 127);
      auto moved = std::move(second);

      check(second.bytes().empty() && moved.bytes().front() == 72);
    }

    check(memory.liveBytes() == 0);
  }

  void testZstdDeclaredSizeBelowBlocks() {
    // A complete frame with a 128 KiB window declares 10 bytes of content but carries RLE blocks of
    // 1 and 131072 bytes: a limit under 128 KiB sizes the storage by that declaration.
    const auto input = decodeHexadecimal("28b52ffd80380a0000000a00004103001042");
    ErasureCheckingAllocator system;
    BudgetAllocator memory{system, 2 * 1024 * 1024};
    MemoryAdapter adapter{memory};

    {
      CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};
      const auto body = decoder.decode(input, "zstd", 1024);

      check(body.failed && !body.decoded && !body.truncated);
      check(std::ranges::equal(body.bytes(), input));
    }

    check(memory.liveBytes() == 0);
  }

  // Text that compresses like a real body: words drawn by a fixed generator, so Huffman coding,
  // literals and matches all take part.
  std::vector<std::uint8_t> bodyText(std::size_t size) {
    constexpr ds::Array<std::string_view, 12> words{"capture ", "header ", "stream ", "origin ", "proxy ", "agent ", "terminal ", "pane\n", "{\"id\":", "42,", "\"value\"", "}\n"};
    std::vector<std::uint8_t> text;
    std::uint32_t state = 0x2545f491;

    while (text.size() < size) {
      state = state * 1664525 + 1013904223;
      const auto word = words[(state >> 16) % words.size()];

      text.insert(text.end(), word.begin(), word.end());
    }

    text.resize(size);
    return text;
  }

  struct Chunk {
    std::size_t bytes;
    int level;
    int strategy;
  };

  // Deflates `input` in chunks, each flushed to its own blocks with the level and strategy given: a
  // level of 0 writes stored blocks, Z_FIXED fixed-Huffman ones, the others dynamic ones.
  std::vector<std::uint8_t> deflateChunks(std::span<const std::uint8_t> input, int window_bits, std::span<const Chunk> chunks) {
    z_stream stream{};

    check(deflateInit2(&stream, chunks.front().level, Z_DEFLATED, window_bits, 8, chunks.front().strategy) == Z_OK);
    std::vector<std::uint8_t> output(deflateBound(&stream, input.size()) + 1024 * chunks.size());
    std::size_t offset = 0;

    stream.next_out = output.data();
    stream.avail_out = static_cast<uInt>(output.size());
    for (std::size_t index = 0; index < chunks.size(); ++index) {
      const auto& chunk = chunks[index];
      const bool last = index + 1 == chunks.size();
      const auto bytes = last ? input.size() - offset : std::min(chunk.bytes, input.size() - offset);

      check(deflateParams(&stream, chunk.level, chunk.strategy) == Z_OK);
      stream.next_in = const_cast<Bytef*>(input.data() + offset);
      stream.avail_in = static_cast<uInt>(bytes);
      check(deflate(&stream, last ? Z_FINISH : Z_FULL_FLUSH) == (last ? Z_STREAM_END : Z_OK) && stream.avail_in == 0);
      offset += bytes;
    }

    output.resize(stream.total_out);
    deflateEnd(&stream);
    return output;
  }

  // The decoded prefix a capture keeps: the plaintext's first bytes, truncated exactly when the
  // plaintext runs past the limit.
  void checkPrefix(std::span<const std::uint8_t> plaintext, std::span<const std::uint8_t> input, std::string_view coding, std::size_t limit) {
    ErasureCheckingAllocator system;
    BudgetAllocator memory{system, 4 * limit + 4 * 1024 * 1024};
    MemoryAdapter adapter{memory};

    {
      CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};
      const auto body = decoder.decode(input, coding, limit);

      check(body.decoded && !body.failed && body.size <= limit);
      check(std::ranges::equal(body.bytes(), plaintext.first(body.size)));
      check(body.truncated == (plaintext.size() > limit));
      check(body.truncated || body.size == plaintext.size());
    }

    check(memory.liveBytes() == 0);
  }

  // Every real zstd body carries compressed blocks, with literals and sequences, not the raw block of
  // the fixture above.
  void testZstdCompressedBlocks() {
    auto compress = [](std::span<const std::uint8_t> plaintext, int minimum_match) {
      const auto context = std::unique_ptr<ZSTD_CCtx, decltype(&ZSTD_freeCCtx)>{ZSTD_createCCtx(), &ZSTD_freeCCtx};

      check(context != nullptr);
      check(!ZSTD_isError(ZSTD_CCtx_setParameter(context.get(), ZSTD_c_compressionLevel, 3)));
      check(!ZSTD_isError(ZSTD_CCtx_setParameter(context.get(), ZSTD_c_minMatch, minimum_match)));
      std::vector<std::uint8_t> compressed(ZSTD_compressBound(plaintext.size()));
      const auto size = ZSTD_compress2(context.get(), compressed.data(), compressed.size(), plaintext.data(), plaintext.size());

      check(!ZSTD_isError(size) && size < plaintext.size());
      compressed.resize(size);
      return compressed;
    };

    // Text compresses to literals and sequences; bytes drawn from 64 values with matches of 7 bytes
    // or more only compress to Huffman-coded literals, blocks without sequences.
    const auto text = bodyText(300 * 1024);
    std::vector<std::uint8_t> symbols(300 * 1024);
    std::uint32_t state = 0x9e3779b9;

    for (auto& symbol : symbols) {
      state = state * 1664525 + 1013904223;
      symbol = static_cast<std::uint8_t>('0' + (state >> 26));
    }

    for (const auto& [plaintext, compressed] : {std::pair{text, compress(text, 3)}, std::pair{symbols, compress(symbols, 7)}}) {
      // 200 KiB stops inside the second block, which a compressed block cannot fill in part.
      for (const std::size_t limit : {std::size_t{1}, std::size_t{4096}, std::size_t{131071}, std::size_t{200 * 1024}, std::size_t{1024 * 1024}}) {
        checkPrefix(plaintext, compressed, "zstd", limit);
      }
    }
  }

  // A body of stored, fixed and dynamic blocks, as servers that flush per chunk send it, decoded with
  // limits over the small-output path, the production default among them.
  void testFlateMultiblockLargeLimit() {
    const auto plaintext = bodyText(300 * 1024);
    const ds::Array chunks{
        Chunk{64 * 1024, 6, Z_DEFAULT_STRATEGY},
        Chunk{64 * 1024, 0, Z_DEFAULT_STRATEGY},
        Chunk{64 * 1024, 6, Z_FIXED},
        Chunk{0, 9, Z_DEFAULT_STRATEGY},
    };

    for (const auto& [coding, window_bits] : {std::pair{std::string_view{"gzip"}, 31}, std::pair{std::string_view{"deflate"}, 15}}) {
      const auto compressed = deflateChunks(plaintext, window_bits, chunks);

      for (const std::size_t limit : {std::size_t{65536}, std::size_t{200 * 1024}, std::size_t{1024 * 1024}}) {
        checkPrefix(plaintext, compressed, coding, limit);
      }
    }
  }

  // A small gzip that expands to 64 MiB: the decoder stops at the limit and its storage grows with
  // the limit, not with the stream.
  void testFlateBombIsBounded() {
    constexpr std::size_t expanded = 64 * 1024 * 1024;
    constexpr std::size_t limit = 1024 * 1024;
    const std::vector<std::uint8_t> zeros(limit);
    z_stream stream{};

    check(deflateInit2(&stream, 9, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) == Z_OK);
    std::vector<std::uint8_t> bomb(256 * 1024);

    stream.next_out = bomb.data();
    stream.avail_out = static_cast<uInt>(bomb.size());
    for (std::size_t offset = 0; offset < expanded; offset += zeros.size()) {
      const bool last = offset + zeros.size() == expanded;

      stream.next_in = const_cast<Bytef*>(zeros.data());
      stream.avail_in = static_cast<uInt>(zeros.size());
      check(deflate(&stream, last ? Z_FINISH : Z_NO_FLUSH) == (last ? Z_STREAM_END : Z_OK) && stream.avail_out != 0);
    }

    bomb.resize(stream.total_out);
    deflateEnd(&stream);
    ErasureCheckingAllocator system;
    BudgetAllocator memory{system, 2 * limit};
    MemoryAdapter adapter{memory};

    {
      CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};
      const auto body = decoder.decode(bomb, "gzip", limit);

      check(body.decoded && !body.failed && body.truncated && body.size == limit);
      check(std::ranges::all_of(body.bytes(), [](std::uint8_t byte) {
        return byte == 0;
      }));
    }

    check(memory.liveBytes() == 0);
  }

  // `gzip file` and nginx's gzip_static write FNAME, and a server may set any of the optional header
  // fields: the decoder skips them all, and a field cut short leaves the body raw.
  void testGzipEnvelopeFields() {
    const auto plaintext = bodyText(512);
    const auto plain = deflateChunks(plaintext, 31, ds::Array{Chunk{0, 6, Z_DEFAULT_STRATEGY}});
    constexpr std::uint8_t extra = 0x04, name = 0x08, comment = 0x10, header_checksum = 0x02;
    std::vector<std::uint8_t> header{plain.begin(), plain.begin() + 10};

    header[3] = extra | name | comment | header_checksum;
    header.insert(header.end(), {6, 0, 'A', 'P', 2, 0, 'x', 'y'});
    for (const std::string_view text : {std::string_view{"body.json"}, std::string_view{"fixture comment"}}) {
      header.insert(header.end(), text.begin(), text.end());
      header.push_back(0);
    }

    const auto checksum = crc32(0, header.data(), static_cast<uInt>(header.size()));

    header.insert(header.end(), {static_cast<std::uint8_t>(checksum), static_cast<std::uint8_t>(checksum >> 8)});
    std::vector<std::uint8_t> full = header;

    full.insert(full.end(), plain.begin() + 10, plain.end());
    checkPrefix(plaintext, full, "gzip", 1024);

    // Each body is cut inside a header field, and the bytes after the cut are the rest of a valid
    // gzip: a decoder that read past the cut would find a stream to decode there.
    struct Cut {
      std::uint8_t flags;
      std::vector<std::uint8_t> fields;
      std::size_t kept;
    };

    const ds::Array cuts{
        Cut{extra, {4, 0, 'A', 'P', 0, 0}, 4},
        Cut{name, {'b', 'o', 'd', 'y', 0}, 4},
        Cut{header_checksum, {0x12, 0x34}, 1},
    };

    for (const auto& cut : cuts) {
      std::vector<std::uint8_t> buffer{plain.begin(), plain.begin() + 10};

      buffer[3] = cut.flags;
      buffer.insert(buffer.end(), cut.fields.begin(), cut.fields.end());
      buffer.insert(buffer.end(), plain.begin() + 10, plain.end());
      const auto input = std::span{buffer}.first(10 + cut.kept);
      ErasureCheckingAllocator system;
      BudgetAllocator memory{system, 1024 * 1024};
      MemoryAdapter adapter{memory};

      {
        CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};
        const auto body = decoder.decode(input, "gzip", 1024);

        check(body.failed && !body.decoded && std::ranges::equal(body.bytes(), input));
      }

      check(memory.liveBytes() == 0);
    }
  }

  struct Decoded {
    std::vector<std::uint8_t> bytes;
    bool decoded;
    bool failed;
  };

  // What the capture keeps of `input` coded as `coding`, decoded under `limit`.
  Decoded decodeCapture(std::span<const std::uint8_t> input, std::string_view coding, std::size_t limit) {
    ErasureCheckingAllocator system;
    BudgetAllocator memory{system, 4 * 1024 * 1024};
    MemoryAdapter adapter{memory};
    Decoded result;

    {
      CaptureContentDecoder decoder{static_cast<Memory&>(adapter)};
      const auto body = decoder.decode(input, coding, limit);

      result = {{body.bytes().begin(), body.bytes().end()}, body.decoded, body.failed};
    }

    check(memory.liveBytes() == 0);
    return result;
  }

  // A body whose coding does not check out is kept as it arrived and marked failed, never shown as a
  // complete decoded body.
  void testCorruptStreamsFallBackRaw() {
    const auto plaintext = bodyText(512);
    const ds::Array chunks{Chunk{256, 6, Z_DEFAULT_STRATEGY}, Chunk{0, 6, Z_DEFAULT_STRATEGY}};
    const auto gzip = deflateChunks(plaintext, 31, chunks);
    const auto zlib = deflateChunks(plaintext, 15, chunks);

    check(decodeCapture(gzip, "gzip", 1024).bytes == plaintext && decodeCapture(zlib, "deflate", 1024).bytes == plaintext);

    // The full flush ends the first chunk with an empty stored block, so the next byte starts a block
    // header: block type 3 is reserved.
    constexpr ds::Array<std::uint8_t, 4> flush{0, 0, 0xff, 0xff};
    const auto boundary = std::ranges::search(zlib, flush);

    check(!boundary.empty() && boundary.end() != zlib.end());
    auto corrupt = zlib;

    corrupt[static_cast<std::size_t>(boundary.end() - zlib.begin())] |= 0x06;
    auto method = zlib;

    method[0] = (method[0] & 0xf0) | 9;
    auto window = zlib;

    window[0] = (8 << 4) | 8;
    auto magic = gzip;

    magic[0] = 0x1e;
    const ds::Array<std::pair<std::string_view, std::vector<std::uint8_t>>, 5> inputs{{
        {"gzip", {gzip.begin(), gzip.end() - 8}},
        {"deflate", corrupt},
        {"deflate", method},
        {"deflate", window},
        {"gzip", magic},
    }};

    for (const auto& [coding, input] : inputs) {
      const auto body = decodeCapture(input, coding, 1024);

      check(body.failed && !body.decoded && body.bytes == input);
    }
  }

  // A body coded twice decodes through both codings, the last listed first. A coding the decoder
  // does not know leaves the body raw without calling it a failure; a malformed list, or an inner
  // coding the limit cuts short, does fail.
  void testStackedAndUnknownCodings() {
    const auto plaintext = bodyText(512);
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    HttpContentCodec codec{memory};
    const auto gzip = codec.encode(plaintext, "gzip", 4096);
    const std::vector<std::uint8_t> inner{gzip.bytes().begin(), gzip.bytes().end()};
    const auto coded = codec.encode(inner, "br", 4096);
    const std::vector<std::uint8_t> wire{coded.bytes().begin(), coded.bytes().end()};

    const auto stacked = decodeCapture(wire, "gzip, br", 1024);

    check(stacked.decoded && !stacked.failed && stacked.bytes == plaintext);

    const auto cut = decodeCapture(wire, "gzip, br", inner.size() - 1);

    check(cut.failed && !cut.decoded && std::ranges::equal(cut.bytes, std::span{wire}.first(std::min(wire.size(), inner.size() - 1))));

    const auto unknown = decodeCapture(wire, "x-custom", 1024);

    check(!unknown.failed && !unknown.decoded && unknown.bytes == wire);

    const auto malformed = decodeCapture(wire, "gzip,,br", 1024);

    check(malformed.failed && !malformed.decoded && malformed.bytes == wire);

    const auto identity = decodeCapture(wire, "identity", 1024);

    check(identity.decoded && !identity.failed && identity.bytes == wire);
  }

  void testCapturePublication() {
    SystemAllocator system;
    BudgetAllocator budget{system, 8 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    ProxyCaptureLimits limits{.part_bytes = 64, .exchange_bytes = 128, .total_bytes = 32768, .enabled = true};
    CaptureProducer producer{memory, limits};

    for (std::size_t index = 0; index < producer.queue_capacity; ++index) {
      auto half = producer.start({.key = {index, 0}, .host = "host"});

      check(half && half.getMut().append(CapturePart::request_body, "x"));
      check(producer.publish(std::move(half)));
    }

    check(!producer.publish(producer.start({})));
    const auto metrics = producer.metrics();

    check(metrics.queued == producer.queue_capacity && metrics.queue_high_water == producer.queue_capacity);
    check(metrics.started == producer.queue_capacity + 1 && metrics.dropped_queue == 1);

    auto first = producer.tryReceive();

    check(first && (*first)->key.connection == 0);
    first.reset();
    producer.close();
    check(producer.reservedBytes() == 0 && producer.metrics().queued == 0 && budget.liveBytes() == 0);
    check(!producer.receive());
    check(!producer.publish(producer.start({})) && producer.metrics().dropped_queue == 2);
    check(!producer.start({.host = std::string(256, 'h')}) && producer.metrics().skipped == 1);
  }

  void testDecodedCaptureCounters() {
    telar::testing::TestMemory adapter;
    SystemAllocator system;
    ConcurrentMemory& memory = adapter;
    ProxyCaptureLimits limits{.part_bytes = 32, .exchange_bytes = 64, .total_bytes = 4096, .enabled = true};
    CaptureProducer producer{memory, limits};
    auto half = producer.start({});

    half.getMut().setEncoding("gzip");
    const auto compressed = decodeHexadecimal("1f8b0800000000000213aba8a03d00008f5d0e5e64000000");

    check(half.getMut().append(CapturePart::request_body, compressed));
    check(producer.publish(std::move(half)) && producer.metrics().truncated == 0);
    auto received = producer.receive();

    producer.decodeBody(received.getMut().getMut());
    check((*received)->body_decoded && (*received)->body.truncated && (*received)->body.size() == 32);
    check(producer.metrics().truncated == 1 && producer.metrics().truncated_part == 1);

    auto malformed = producer.start({});

    malformed.getMut().setEncoding("br");
    malformed.getMut().append(CapturePart::request_body, "broken");
    producer.decodeBody(malformed.getMut());
    check(producer.metrics().decode_failed == 1 && malformed->body.size() == 6 && !malformed->body_decoded);

    BudgetAllocator failing{system, 0};
    SynchronizedAllocator synchronized{failing};
    MemoryAdapter failing_adapter{synchronized};
    CaptureProducer exhausted{static_cast<ConcurrentMemory&>(failing_adapter), limits};

    check(!exhausted.start({}) && exhausted.metrics().skipped == 1 && exhausted.metrics().started == 0);
  }

  void testConcurrentCaptureDelivery() {
    DropChannel<std::uint64_t, 8> channel;
    std::atomic<std::uint64_t> published{0};
    std::uint64_t received = 0;
    std::jthread consumer{[&] {
      while (const auto value = channel.receive()) {
        received += *value;
      }
    }};

    ds::Array<std::jthread, 4> producers;

    for (auto& thread : producers.viewMut()) {
      thread = std::jthread{[&] {
        for (std::uint64_t iteration = 1; iteration <= 1000; ++iteration) {
          if (channel.publish(iteration)) {
            published.fetch_add(iteration, std::memory_order_relaxed);
          }
        }
      }};
    }

    for (auto& thread : producers.viewMut()) {
      thread.join();
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};

    while (channel.metrics().queued != 0 && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::yield();
    }

    check(channel.metrics().queued == 0);
    channel.close();
    consumer.join();
    check(received == published.load(std::memory_order_relaxed));
  }

  const telar::testing::Case case_capture_publication{"capture_decode.capture_publication", testCapturePublication};
  const telar::testing::Case case_decoded_capture_counters{"capture_decode.decoded_capture_counters", testDecodedCaptureCounters};
  const telar::testing::Case case_concurrent_capture_delivery{"capture_decode.concurrent_capture_delivery", testConcurrentCaptureDelivery};
  const telar::testing::Case case_capture_decoding{"capture_decode.capture_decoding", testCaptureDecoding};
  const telar::testing::Case case_zstd_compressed_blocks{"capture_decode.zstd_compressed_blocks", testZstdCompressedBlocks};
  const telar::testing::Case case_flate_multiblock_large_limit{"capture_decode.flate_multiblock_large_limit", testFlateMultiblockLargeLimit};
  const telar::testing::Case case_flate_bomb_is_bounded{"capture_decode.flate_bomb_is_bounded", testFlateBombIsBounded};
  const telar::testing::Case case_gzip_envelope_fields{"capture_decode.gzip_envelope_fields", testGzipEnvelopeFields};
  const telar::testing::Case case_zstd_declared_size_below_blocks{"capture_decode.zstd_declared_size_below_blocks", testZstdDeclaredSizeBelowBlocks};
  const telar::testing::Case case_corrupt_streams_fall_back_raw{"capture_decode.corrupt_streams_fall_back_raw", testCorruptStreamsFallBackRaw};
  const telar::testing::Case case_stacked_and_unknown_codings{"capture_decode.stacked_and_unknown_codings", testStackedAndUnknownCodings};

}
