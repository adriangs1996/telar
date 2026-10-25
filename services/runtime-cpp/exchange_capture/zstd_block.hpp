#pragma once

#include <cstdint>
#include <optional>
#include <span>

namespace telar::runtime {

struct ZstdBlock {
  enum class Kind { raw,
                    repeated,
                    compressed,
                    reserved };

  static ZstdBlock parse(std::span<const std::uint8_t, 3> bytes) noexcept {
    const auto value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
    return {static_cast<Kind>((value >> 1) & 3), static_cast<std::size_t>(value >> 3)};
  }

  struct Literals {
    std::size_t regenerated_size;
    bool has_sequences;
  };

  static std::optional<Literals> literals(std::span<const std::uint8_t> bytes) noexcept {
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
  static std::optional<std::uint64_t> read(std::span<const std::uint8_t> bytes, std::size_t count) noexcept {
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
