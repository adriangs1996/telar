#pragma once

#include "../text/base64.hpp"
#include "display_cells.hpp"
#include "kitty_command_scanner.hpp"
#include "kitty_control.hpp"

namespace telar::runtime {

class KittyCursor {
public:
  std::optional<DisplayCells> observe(const KittyCommandView &command, std::uint32_t cell_width, std::uint32_t cell_height) noexcept {
    const auto header = parse(command);
    if (!header || command.truncated || (header->image_id != 0 && header->image_number != 0)) {
      return std::nullopt;
    }

    if (pending_) {
      if (header->transmits()) {
        if (header->more) {
          return std::nullopt;
        }

        const auto first = *pending_;
        pending_.reset();
        return execute(first, cell_width, cell_height);
      }
      if (header->action == 'd') {
        pending_.reset();
      }
    } else if (header->transmits() && header->more) {
      pending_ = *header;
      return std::nullopt;
    }

    return execute(*header, cell_width, cell_height);
  }

private:
  struct ImageSize {
    std::uint32_t image_id = 0;
    std::uint32_t image_number = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
  };

  struct Header : ImageSize {
    char action = 't';
    char target = 'a';
    std::uint32_t source_x = 0;
    std::uint32_t source_y = 0;
    std::uint32_t source_width = 0;
    std::uint32_t source_height = 0;
    DisplayCells requested;
    std::uint32_t offset_x = 0;
    std::uint32_t offset_y = 0;
    bool stays = false;
    bool more = false;

    bool transmits() const noexcept {
      return action == 't' || action == 'T';
    }
  };

  std::optional<DisplayCells> execute(const Header &header, std::uint32_t cell_width, std::uint32_t cell_height) noexcept {
    if (header.transmits() && header.width != 0 && header.height != 0 && (header.image_id != 0 || header.image_number != 0)) {
      auto *slot = find(header);
      if (slot == nullptr) {
        slot = &sizes_[next_size_];
        next_size_ = (next_size_ + 1) % sizes_.size();
      }
      *slot = header;
    }

    if (header.action == 'd') {
      if (header.target == 'A') {
        sizes_.fill({});
      } else if (header.target == 'I' || header.target == 'N') {
        if (auto *slot = find(header)) {
          *slot = {};
        }
      }
      return std::nullopt;
    }
    if ((header.action != 'T' && header.action != 'p') || header.stays) {
      return std::nullopt;
    }

    auto width = header.width;
    auto height = header.height;
    if (header.action == 'p') {
      const auto *known = find(header);
      if (known == nullptr) {
        return std::nullopt;
      }
      width = known->width;
      height = known->height;
    }
    if ((width == 0 || height == 0) && (header.requested.columns == 0 || header.requested.rows == 0)) {
      return std::nullopt;
    }

    const auto source_x = std::min(header.source_x, width);
    const auto source_y = std::min(header.source_y, height);
    const auto cells = displayCells({.width = std::min(header.source_width != 0 ? header.source_width : width, width - source_x),
                                     .height = std::min(header.source_height != 0 ? header.source_height : height, height - source_y),
                                     .requested = header.requested,
                                     .offset_x = header.offset_x,
                                     .offset_y = header.offset_y,
                                     .cell_width = cell_width,
                                     .cell_height = cell_height});
    return cells.columns != 0 && cells.rows != 0 ? std::optional{cells} : std::nullopt;
  }

  ImageSize *find(const Header &header) noexcept {
    for (auto &size : sizes_) {
      if ((header.image_id != 0 && size.image_id == header.image_id) || (header.image_id == 0 && header.image_number != 0 && size.image_number == header.image_number)) {
        return &size;
      }
    }
    return nullptr;
  }

  static std::optional<Header> parse(const KittyCommandView &command) noexcept {
    Header header;
    constexpr std::uint32_t png_format = 100;
    constexpr std::uint32_t rgba_format = 32;
    auto format = rgba_format;
    bool direct = true;
    bool compressed = false;
    KittyControlFields fields{command.control};
    while (const auto field = fields.next()) {
      const auto number = kittyUnsigned<std::uint32_t>(field->value).value_or(0);
      switch (field->key) {
      case 'a':
        header.action = field->value.front();
        break;
      case 'i':
        header.image_id = number;
        break;
      case 'I':
        header.image_number = number;
        break;
      case 'd':
        header.target = field->value.front();
        break;
      case 'f':
        format = number;
        break;
      case 's':
        header.width = number;
        break;
      case 'v':
        header.height = number;
        break;
      case 'x':
        header.source_x = number;
        break;
      case 'y':
        header.source_y = number;
        break;
      case 'w':
        header.source_width = number;
        break;
      case 'h':
        header.source_height = number;
        break;
      case 'c':
        header.requested.columns = number;
        break;
      case 'r':
        header.requested.rows = number;
        break;
      case 'X':
        header.offset_x = number;
        break;
      case 'Y':
        header.offset_y = number;
        break;
      case 'C':
      case 'U':
        header.stays |= number == 1;
        break;
      case 'P':
        header.stays = true;
        break;
      case 'm':
        header.more = number != 0;
        break;
      case 't':
        direct = field->value.front() == 'd';
        break;
      case 'o':
        compressed = true;
        break;
      default:
        break;
      }
    }
    if (!fields.valid()) {
      return std::nullopt;
    }

    if (format == png_format) {
      header.width = 0;
      header.height = 0;
      if (direct && !compressed) {
        if (const auto size = pngSize(command.payload_prefix)) {
          header.width = (*size)[0];
          header.height = (*size)[1];
        }
      }
    }
    return header;
  }

  static std::optional<std::array<std::uint32_t, 2>> pngSize(std::string_view encoded) noexcept {
    constexpr std::string_view signature = "\x89PNG\r\n\x1a\n";
    constexpr std::size_t encoded_header_size = 32;
    constexpr std::size_t width_offset = 16;
    constexpr std::size_t height_offset = 20;
    constexpr std::size_t chunk_type_offset = 12;
    std::array<std::uint8_t, 24> bytes;
    if (encoded.size() < encoded_header_size || base64::decode(encoded.substr(0, encoded_header_size), bytes) != bytes.size() ||
        std::memcmp(bytes.data(), signature.data(), signature.size()) != 0 || std::memcmp(bytes.data() + chunk_type_offset, "IHDR", 4) != 0) {
      return std::nullopt;
    }

    const auto bigEndian = [&](std::size_t offset) {
      return (static_cast<std::uint32_t>(bytes[offset]) << 24) | (static_cast<std::uint32_t>(bytes[offset + 1]) << 16) | (static_cast<std::uint32_t>(bytes[offset + 2]) << 8) | bytes[offset + 3];
    };
    return std::array{bigEndian(width_offset), bigEndian(height_offset)};
  }

  static constexpr std::size_t image_capacity = 64;
  std::array<ImageSize, image_capacity> sizes_{};
  std::optional<Header> pending_;
  std::size_t next_size_ = 0;
};

}
