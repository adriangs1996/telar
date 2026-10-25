#pragma once

#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <span>

namespace telar::runtime {

enum class FlateContainer { gzip,
                            zlib };

class FlateEnvelope {
public:
  static std::optional<std::size_t> bodyOffset(std::span<const std::uint8_t> input, FlateContainer container) noexcept {
    if (container == FlateContainer::zlib) {
      constexpr std::size_t header_size = 2;
      constexpr unsigned compression_method = 8;
      constexpr unsigned maximum_window_bits = 7;
      if (input.size() < header_size || (input[0] & 15) != compression_method || (input[0] >> 4) > maximum_window_bits) {
        return std::nullopt;
      }
      return header_size;
    }

    constexpr std::size_t header_size = 10;
    constexpr std::uint8_t magic_first = 0x1f;
    constexpr std::uint8_t magic_second = 0x8b;
    constexpr std::uint8_t compression_method = 8;
    if (input.size() < header_size || input[0] != magic_first || input[1] != magic_second || input[2] != compression_method) {
      return std::nullopt;
    }

    const auto flags = input[3];
    auto offset = header_size;
    if (flags & static_cast<unsigned>(GzipFlag::extra)) {
      if (input.size() - offset < sizeof(std::uint16_t)) {
        return std::nullopt;
      }
      const auto length = static_cast<std::size_t>(input[offset] | (input[offset + 1] << 8));
      offset += sizeof(std::uint16_t);
      if (length > input.size() - offset) {
        return std::nullopt;
      }
      offset += length;
    }

    for (const auto field : {GzipFlag::name, GzipFlag::comment}) {
      if (flags & static_cast<unsigned>(field)) {
        while (offset < input.size() && input[offset] != 0) {
          ++offset;
        }
        if (offset == input.size()) {
          return std::nullopt;
        }
        ++offset;
      }
    }
    if (flags & static_cast<unsigned>(GzipFlag::header_checksum)) {
      if (input.size() - offset < sizeof(std::uint16_t)) {
        return std::nullopt;
      }
      offset += sizeof(std::uint16_t);
    }
    return offset;
  }

  static constexpr std::size_t footerSize(FlateContainer container) noexcept {
    return container == FlateContainer::gzip ? 2 * sizeof(std::uint32_t) : sizeof(std::uint32_t);
  }

private:
  enum class GzipFlag : unsigned { header_checksum = 2,
                                   extra = 4,
                                   name = 8,
                                   comment = 16 };
};

}
