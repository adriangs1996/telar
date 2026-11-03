#pragma once

#include "../exchange_capture/decoded_body.hpp"
#include "../exchange_capture/decoder_memory.hpp"
#include "telar_base/text/ascii.hpp"
#include "telar_base/text/fields.hpp"
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>
#define ZSTD_STATIC_LINKING_ONLY
#include <array>
#include <memory>
#include <stdexcept>
#include <zstd.h>

namespace telar::runtime {

// Editing requires complete, validated entities. Observation's prefix decoders are deliberately looser.
template <Allocator Memory>
class HttpContentCodec {
  enum class Coding { identity, gzip, deflate, brotli, zstd };

  struct Flate {
    Flate(Memory &upstream, bool encode, int window) : memory(upstream), encoding(encode) {
      stream.zalloc = &DecoderMemory<Memory>::allocateArray;
      stream.zfree = &DecoderMemory<Memory>::release;
      stream.opaque = &memory;
      const auto result = encoding ? deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window, memory_level, Z_DEFAULT_STRATEGY) : inflateInit2(&stream, window);
      if (result != Z_OK) { throw std::bad_alloc{}; }
    }

    ~Flate() { if (encoding) { deflateEnd(&stream); } else { inflateEnd(&stream); } }
    Flate(const Flate &) = delete;
    Flate &operator=(const Flate &) = delete;
    static constexpr int memory_level = 8;
    DecoderMemory<Memory> memory;
    z_stream stream{};
    bool encoding;
  };

public:
  explicit HttpContentCodec(Memory &memory) noexcept : memory_(memory) {}

  auto decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) -> DecodedBody<Memory> {
    return transform(input, encoding, limit, false);
  }

  auto encode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) -> DecodedBody<Memory> {
    return transform(input, encoding, limit, true);
  }

private:
  auto transform(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit, bool encode) -> DecodedBody<Memory> {
    if (limit == 0 || limit > maximum_bytes || input.size() > maximum_bytes) {
      throw std::length_error{"Invalid HTTP content limit"};
    }

    std::array<Coding, maximum_codings> codings;
    std::size_t count = 0;
    if (!encoding.empty()) {
      TextFields fields{encoding, ","};
      while (const auto field = fields.next()) {
        if (count == codings.size()) { throw std::invalid_argument{"Too many HTTP content codings"}; }
        codings[count++] = coding(trimText(*field, " \t"));
      }
    }

    std::optional<DecodedBody<Memory>> previous;
    for (std::size_t step = 0; step < count; ++step) {
      const auto selected = codings[encode ? step : count - step - 1];
      if (selected == Coding::identity) { continue; }
      const auto capacity = step + 1 == count ? limit : std::min(maximum_bytes, limit + coding_overhead_bytes);
      auto output = one(input, selected, capacity, encode);
      previous = std::move(output);
      input = previous->bytes();
    }
    if (input.size() > limit) { throw std::length_error{"HTTP entity exceeds its limit"}; }
    if (previous) { return std::move(*previous); }

    DecodedBody<Memory> result{memory_, input.size()};
    std::ranges::copy(input, result.storage.bytes().begin());
    result.size = input.size();
    result.decoded = !encode;
    return result;
  }

  static Coding coding(std::string_view value) {
    if (asciiEqualIgnoreCase(value, "identity")) { return Coding::identity; }
    if (asciiEqualIgnoreCase(value, "gzip")) { return Coding::gzip; }
    if (asciiEqualIgnoreCase(value, "deflate")) { return Coding::deflate; }
    if (asciiEqualIgnoreCase(value, "br")) { return Coding::brotli; }
    if (asciiEqualIgnoreCase(value, "zstd")) { return Coding::zstd; }
    throw std::invalid_argument{"Unsupported HTTP content coding"};
  }

  auto one(std::span<const std::uint8_t> input, Coding selected, std::size_t limit, bool encode) -> DecodedBody<Memory> {
    DecodedBody<Memory> result{memory_, limit + 1};
    auto output = result.storage.bytes();
    if (selected == Coding::gzip || selected == Coding::deflate) {
      result.size = flate(input, output, selected == Coding::gzip, encode);
    } else if (selected == Coding::brotli) {
      result.size = brotli(input, output, encode);
    } else {
      result.size = zstd(input, output, encode);
    }
    if (result.size > limit) { throw std::length_error{"HTTP entity exceeds its limit"}; }

    result.decoded = !encode;
    return result;
  }

  auto flate(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool gzip, bool encode) -> std::size_t {
    const int window = gzip ? MAX_WBITS + gzip_window_offset : MAX_WBITS;
    Flate state{memory_, encode, window};
    auto &stream = state.stream;
    stream.next_in = const_cast<std::uint8_t *>(input.data());
    stream.avail_in = static_cast<uInt>(input.size());
    stream.next_out = output.data();
    stream.avail_out = static_cast<uInt>(output.size());
    for (;;) {
      const auto before_input = stream.avail_in;
      const auto before_output = stream.avail_out;
      const auto result = encode ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH);
      if (result == Z_STREAM_END) {
        if (stream.avail_in == 0) { return output.size() - stream.avail_out; }
        if (!encode && gzip && inflateReset2(&stream, window) == Z_OK) { continue; }
        throw std::invalid_argument{"Trailing HTTP compressed bytes"};
      }
      if (stream.avail_out == 0) { throw std::length_error{"HTTP entity exceeds its limit"}; }
      if (result != Z_OK || (stream.avail_in == before_input && stream.avail_out == before_output)) {
        throw std::invalid_argument{"Invalid or incomplete HTTP compressed entity"};
      }
    }
  }

  auto brotli(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool encode) -> std::size_t {
    DecoderMemory memory{memory_};
    auto remaining_input = input.size();
    auto remaining_output = output.size();
    const auto *next_input = input.data();
    auto *next_output = output.data();
    if (encode) {
      auto state = std::unique_ptr<BrotliEncoderState, decltype(&BrotliEncoderDestroyInstance)>{BrotliEncoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory), &BrotliEncoderDestroyInstance};
      if (!state) { throw std::bad_alloc{}; }
      if (!BrotliEncoderSetParameter(state.get(), BROTLI_PARAM_QUALITY, brotli_quality)) { throw std::invalid_argument{"Invalid Brotli parameters"}; }
      while (!BrotliEncoderIsFinished(state.get())) {
        const auto before_input = remaining_input;
        const auto before_output = remaining_output;
        if (!BrotliEncoderCompressStream(state.get(), BROTLI_OPERATION_FINISH, &remaining_input, &next_input, &remaining_output, &next_output, nullptr)) { throw std::invalid_argument{"Brotli encoding failed"}; }
        if (BrotliEncoderIsFinished(state.get())) { break; }
        if (remaining_output == 0 || (remaining_input == before_input && remaining_output == before_output)) { throw std::length_error{"HTTP entity exceeds its limit"}; }
      }
    } else {
      auto state = std::unique_ptr<BrotliDecoderState, decltype(&BrotliDecoderDestroyInstance)>{BrotliDecoderCreateInstance(&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory), &BrotliDecoderDestroyInstance};
      if (!state) { throw std::bad_alloc{}; }
      const auto result = BrotliDecoderDecompressStream(state.get(), &remaining_input, &next_input, &remaining_output, &next_output, nullptr);
      if (remaining_output == 0 && result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) { throw std::length_error{"HTTP entity exceeds its limit"}; }
      if (result != BROTLI_DECODER_RESULT_SUCCESS || remaining_input != 0) { throw std::invalid_argument{"Invalid or incomplete Brotli entity"}; }
    }
    return output.size() - remaining_output;
  }

  auto zstd(std::span<const std::uint8_t> input, std::span<std::uint8_t> output, bool encode) -> std::size_t {
    DecoderMemory memory{memory_};
    const ZSTD_customMem allocator{&DecoderMemory<Memory>::allocate, &DecoderMemory<Memory>::release, &memory};
    if (encode) {
      auto state = std::unique_ptr<ZSTD_CCtx, decltype(&ZSTD_freeCCtx)>{ZSTD_createCCtx_advanced(allocator), &ZSTD_freeCCtx};
      if (!state) { throw std::bad_alloc{}; }
      if (ZSTD_isError(ZSTD_CCtx_setParameter(state.get(), ZSTD_c_checksumFlag, 1))) { throw std::invalid_argument{"Invalid Zstd parameters"}; }
      const auto size = ZSTD_compress2(state.get(), output.data(), output.size(), input.data(), input.size());
      if (ZSTD_isError(size)) { throw std::length_error{"HTTP Zstd encoding exceeds its limit"}; }
      return size;
    }

    auto state = std::unique_ptr<ZSTD_DCtx, decltype(&ZSTD_freeDCtx)>{ZSTD_createDCtx_advanced(allocator), &ZSTD_freeDCtx};
    if (!state) { throw std::bad_alloc{}; }
    if (ZSTD_isError(ZSTD_DCtx_setParameter(state.get(), ZSTD_d_windowLogMax, maximum_window_log))) { throw std::invalid_argument{"Invalid Zstd parameters"}; }
    ZSTD_inBuffer source{input.data(), input.size(), 0};
    ZSTD_outBuffer destination{output.data(), output.size(), 0};
    for (;;) {
      const auto before_input = source.pos;
      const auto before_output = destination.pos;
      const auto remaining = ZSTD_decompressStream(state.get(), &destination, &source);
      if (ZSTD_isError(remaining)) { throw std::invalid_argument{"Invalid Zstd entity"}; }
      if (remaining == 0 && source.pos == source.size) { return destination.pos; }
      if (destination.pos == destination.size) { throw std::length_error{"HTTP entity exceeds its limit"}; }
      if (before_input == source.pos && before_output == destination.pos) { throw std::invalid_argument{"Incomplete Zstd entity"}; }
    }
  }

  static constexpr std::size_t maximum_bytes = 16 * 1024 * 1024;
  static constexpr std::size_t maximum_codings = 2;
  static constexpr std::size_t coding_overhead_bytes = 64 * 1024;
  static constexpr int gzip_window_offset = 16;
  static constexpr int maximum_window_log = 23;
  static constexpr unsigned brotli_quality = 4;
  Memory &memory_;
};

}
