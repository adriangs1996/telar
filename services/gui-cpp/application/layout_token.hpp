#pragma once

#include "core/memory.hpp"
#include "pane_layout.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "text/hexadecimal.hpp"
#include <array>
#include <charconv>
#include <cstddef>
#include <span>
#include <string_view>

namespace telar::gui {

struct TabLayoutPreset {
  TabLocation location;
  PaneLayout layout;
  std::uint64_t focused_pane = 0;
  bool fullscreen = false;
};

class LayoutToken {
public:
  static constexpr std::size_t text_capacity = 4096;
  static constexpr std::size_t digits_per_byte = 2;
  static constexpr std::size_t binary_capacity = text_capacity / digits_per_byte;

  template <Allocator Memory>
  static std::string_view write(const ClientLayoutSnapshot &snapshot, String<Memory> &output) {
    std::array<Byte, binary_capacity> binary{};
    const auto encoded = Codec::encode(snapshot, binary);
    output.clear();
    output.reserve(encoded.size() * digits_per_byte);
    runtime::appendLowerHex(output, encoded);

    return output;
  }

  static TabLayoutPreset read(std::string_view text) {
    std::array<Byte, binary_capacity> binary{};
    const auto bytes = decodeHexadecimal(text, binary);
    constexpr auto storage_capacity = (PaneLayout::maximum_nodes * sizeof(ClientLayoutNode)) + sizeof(ClientTabLayout) + alignof(ClientLayoutNode) + alignof(ClientTabLayout);
    std::array<Byte, storage_capacity> elements{};
    DecodeStorage storage{elements};
    const auto snapshot = Codec::decode<ClientLayoutSnapshot>(bytes, storage);
    if (!snapshot.restored || !snapshot.active_tab || snapshot.tabs.size() != 1) {
      throw EncodingError{"Layout token must describe one restored tab"};
    }

    const auto &tab = snapshot.tabs.front();
    if (!sameTab(tab.location, *snapshot.active_tab)) {
      throw EncodingError{"Layout token tab does not match its active tab"};
    }

    TabLayoutPreset preset;
    preset.location = tab.location;
    preset.focused_pane = tab.focused_pane;
    preset.fullscreen = tab.fullscreen;
    preset.layout.restore(tab.nodes);

    return preset;
  }

private:
  static std::span<const Byte> decodeHexadecimal(std::string_view text, std::span<Byte> output) {
    if (text.empty() || text.size() > text_capacity || text.size() % digits_per_byte != 0) {
      throw EncodingError{"Invalid hexadecimal layout token length"};
    }

    constexpr int hexadecimal_base = 16;
    const auto size = text.size() / digits_per_byte;
    for (std::size_t index = 0; index < size; ++index) {
      const auto digits = text.substr(index * digits_per_byte, digits_per_byte);
      unsigned value = 0;
      const auto parsed = std::from_chars(digits.data(), digits.data() + digits.size(), value, hexadecimal_base);
      if (parsed.ec != std::errc{} || parsed.ptr != digits.data() + digits.size()) {
        throw EncodingError{"Invalid hexadecimal layout token digit"};
      }

      output[index] = static_cast<Byte>(value);
    }

    return output.first(size);
  }
};

}
