#pragma once

#include "kitty_control.hpp"
#include <cstdint>

namespace telar::runtime {

struct KittyFileRange {
  std::uint64_t offset = 0;
  std::optional<std::uint64_t> size;
  bool temporary = false;

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
        if (field->value != "f" && field->value != "t") {
          return std::nullopt;
        }
        file = true;
        range.temporary = field->value == "t";
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

}
