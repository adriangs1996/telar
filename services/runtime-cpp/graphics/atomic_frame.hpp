#pragma once

#include "kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>

namespace telar::runtime {

enum class GraphicsInputMedium {
  shared_memory,
  file
};

struct AtomicFrameKey {
  std::uint32_t image_id;
  std::uint32_t placement_id;

  bool operator==(const AtomicFrameKey &) const noexcept = default;
};

struct AtomicFrameControl {
  AtomicFrameKey key;
  GraphicsInputMedium medium;
  std::uint32_t width;
  std::uint32_t height;
  std::uint8_t depth;
  std::size_t byte_count;

  static std::optional<AtomicFrameControl> parse(std::string_view text) noexcept {
    std::optional<std::uint32_t> image, placement, width, height, depth;
    std::optional<GraphicsInputMedium> medium;
    bool transmit = false;
    bool cursor_static = false;
    bool quiet = false;
    KittyControlFields fields{text};
    while (const auto field = fields.next()) {
      switch (field->key) {
      case 'a':
        if (transmit || field->value != "T") {
          return std::nullopt;
        }
        transmit = true;
        break;
      case 't':
        if (medium || (field->value != "s" && field->value != "f")) {
          return std::nullopt;
        }
        medium = field->value == "s" ? GraphicsInputMedium::shared_memory : GraphicsInputMedium::file;
        break;
      case 'C':
        if (cursor_static || field->value != "1") {
          return std::nullopt;
        }
        cursor_static = true;
        break;
      case 'q':
        if (quiet || field->value != "2") {
          return std::nullopt;
        }
        quiet = true;
        break;
      case 'i':
      case 'p':
      case 's':
      case 'v':
      case 'f': {
        auto &destination = field->key == 'i' ? image : field->key == 'p' ? placement
                                                    : field->key == 's'   ? width
                                                    : field->key == 'v'   ? height
                                                                          : depth;
        const auto value = kittyUnsigned<std::uint32_t>(field->value);
        if (destination || !value || *value == 0) {
          return std::nullopt;
        }
        destination = *value;
        break;
      }
      default:
        return std::nullopt;
      }
    }

    constexpr std::uint32_t rgb_depth = 24;
    constexpr std::uint32_t rgba_depth = 32;
    if (!fields.valid() || !transmit || !cursor_static || !quiet || !medium || !image || !placement || !width || !height || !depth || (*depth != rgb_depth && *depth != rgba_depth)) {
      return std::nullopt;
    }

    const auto pixels = static_cast<std::uint64_t>(*width) * *height;
    const auto bytes_per_pixel = *depth == rgb_depth ? 3 : 4;
    if (pixels > SIZE_MAX / bytes_per_pixel) {
      return std::nullopt;
    }

    return AtomicFrameControl{{*image, *placement}, *medium, *width, *height, static_cast<std::uint8_t>(*depth), static_cast<std::size_t>(pixels * bytes_per_pixel)};
  }
};

struct AtomicFrame {
  std::size_t start;
  std::size_t end;
  std::size_t command_start;
  std::size_t command_end;
  std::string_view encoded_name;
  AtomicFrameControl control;
  bool cursor_wrapped;

  static std::optional<AtomicFrame> at(std::string_view bytes, std::size_t start) noexcept {
    if (start > bytes.size()) {
      return std::nullopt;
    }

    const bool wrapped = bytes.substr(start).starts_with(cursor_save);
    const auto envelope = start + (wrapped ? cursor_save.size() : 0);
    if (!bytes.substr(envelope).starts_with(prefix)) {
      return std::nullopt;
    }

    const auto control_start = envelope + prefix.size();
    const auto terminator = bytes.find(command_terminator, control_start);
    if (terminator == std::string_view::npos || !bytes.substr(terminator).starts_with(suffix)) {
      return std::nullopt;
    }

    const auto end = terminator + suffix.size();
    if (wrapped && !bytes.substr(end).starts_with(cursor_restore)) {
      return std::nullopt;
    }

    const auto command = bytes.substr(control_start, terminator - control_start);
    const auto separator = command.find(';');
    if (separator == std::string_view::npos || separator + 1 == command.size()) {
      return std::nullopt;
    }

    const auto control = AtomicFrameControl::parse(command.substr(0, separator));
    if (!control) {
      return std::nullopt;
    }

    return AtomicFrame{start, end + (wrapped ? cursor_restore.size() : 0), control_start - introducer.size(), terminator + command_terminator.size(), command.substr(separator + 1), *control, wrapped};
  }

  static std::optional<AtomicFrame> find(std::string_view bytes, std::size_t from) noexcept {
    for (auto start = bytes.find(prefix, from); start != std::string_view::npos; start = bytes.find(prefix, start + prefix.size())) {
      if (start >= cursor_save.size() && start - cursor_save.size() >= from && bytes.substr(start - cursor_save.size()).starts_with(cursor_save)) {
        if (auto wrapped = at(bytes, start - cursor_save.size())) {
          return wrapped;
        }
      }

      if (auto frame = at(bytes, start)) {
        return frame;
      }
    }
    return std::nullopt;
  }

  static constexpr std::string_view prefix = "\x1b[?2026h\x1b[H\x1b_G";
  static constexpr std::string_view suffix = "\x1b\\\x1b[?2026l";
  static constexpr std::string_view cursor_save = "\x1b"
                                                  "7";
  static constexpr std::string_view cursor_restore = "\x1b"
                                                     "8";
  static constexpr std::string_view introducer = "\x1b_G";
  static constexpr std::string_view command_terminator = "\x1b\\";
};

struct AtomicFrameView {
  std::span<const std::uint8_t> bytes;
  std::size_t command_start;
  std::size_t command_end;
  std::string_view encoded_name;
  AtomicFrameControl control;
};

struct AtomicFrameResource {
  std::string_view encoded_name;
  std::size_t byte_count;
  std::size_t limit;
  GraphicsInputMedium medium;
};

}
