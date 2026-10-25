#pragma once

#include "../diagnostics/trace.hpp"
#include "../memory/sensitive_buffer.hpp"
#include "../text/ascii.hpp"
#include "../text/fields.hpp"
#include "brotli_decoder.hpp"
#include "decoded_body.hpp"
#include "flate_decoder.hpp"
#include "zstd_decoder.hpp"
#include <array>
#include <stdexcept>

namespace telar::runtime {

template <Allocator Memory>
class CaptureContentDecoder {
public:
  explicit CaptureContentDecoder(Memory &memory) noexcept : memory_(memory) {}

  DecodedBody<Memory> decode(std::span<const std::uint8_t> input, std::string_view encoding, std::size_t limit) {
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
  DecodedBody<Memory> raw(std::span<const std::uint8_t> input, std::size_t limit, bool failed) {
    const auto accepted = std::min(input.size(), limit);
    DecodedBody<Memory> result{memory_, accepted};
    std::copy_n(input.data(), accepted, result.storage.bytes().data());
    result.size = accepted;
    result.truncated = accepted != input.size();
    result.failed = failed;
    return result;
  }

  static bool supported(std::string_view coding) noexcept {
    return asciiEqualIgnoreCase(coding, "gzip") || asciiEqualIgnoreCase(coding, "deflate") || asciiEqualIgnoreCase(coding, "br") || asciiEqualIgnoreCase(coding, "zstd");
  }

  std::optional<DecodedBody<Memory>> decodeOne(std::span<const std::uint8_t> input, std::string_view coding, std::size_t limit) {
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

  std::optional<DecodedBody<Memory>> decodeSmallFlate(std::span<const std::uint8_t> input, FlateContainer container, std::size_t limit) {
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

}
