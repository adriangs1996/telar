#pragma once

#include "kitty_control.hpp"
#include <cstdint>

namespace telar::runtime {

struct KittyFileRange {
  std::uint64_t offset = 0;
  std::optional<std::uint64_t> size;

  static std::optional<KittyFileRange> parse(std::string_view control) noexcept {
    KittyFileRange range;
    bool file = false;
    KittyControlFields fields{control};
    while (const auto field = fields.next()) {
      switch (field->key) {
      case 'a':
        if (field->value != "t" && field->value != "T") {
          return std::nullopt;
        }
        break;
      case 't':
        if (field->value != "f") {
          return std::nullopt;
        }
        file = true;
        break;
      case 'm':
        if (field->value != "0") {
          return std::nullopt;
        }
        break;
      case 'S':
      case 'O': {
        const auto number = kittyUnsigned<std::uint64_t>(field->value);
        if (!number) {
          return std::nullopt;
        }
        if (field->key == 'S') {
          range.size = *number;
        } else {
          range.offset = *number;
        }
        break;
      }
      default:
        break;
      }
    }
    return file && fields.valid() ? std::optional{range} : std::nullopt;
  }
};

struct KittyFileQuery {
  std::uint32_t image_id;
  std::uint64_t bytes;

  static std::optional<KittyFileQuery> parse(std::string_view control) noexcept {
    bool query = false;
    bool file = false;
    std::optional<std::uint32_t> identity, width, height, format;
    KittyControlFields fields{control};
    while (const auto field = fields.next()) {
      switch (field->key) {
      case 'a':
        if (query || field->value != "q") {
          return std::nullopt;
        }
        query = true;
        break;
      case 't':
        if (file || field->value != "f") {
          return std::nullopt;
        }
        file = true;
        break;
      case 'i':
      case 's':
      case 'v':
      case 'f': {
        auto &destination = field->key == 'i' ? identity : field->key == 's' ? width
                                                       : field->key == 'v'   ? height
                                                                             : format;
        const auto value = kittyUnsigned<std::uint32_t>(field->value);
        if (destination || !value || *value == 0) {
          return std::nullopt;
        }
        destination = *value;
        break;
      }
      case 'q':
        break;
      default:
        return std::nullopt;
      }
    }

    constexpr std::uint32_t rgb_depth = 24;
    constexpr std::uint32_t rgba_depth = 32;
    const auto depth = format.value_or(rgba_depth);
    if (!fields.valid() || !query || !file || !identity || !width || !height || (depth != rgb_depth && depth != rgba_depth)) {
      return std::nullopt;
    }

    const auto pixels = static_cast<std::uint64_t>(*width) * *height;
    const auto bytes_per_pixel = depth == rgb_depth ? 3 : 4;
    if (pixels > UINT64_MAX / bytes_per_pixel) {
      return std::nullopt;
    }
    return KittyFileQuery{*identity, pixels * bytes_per_pixel};
  }
};

}
