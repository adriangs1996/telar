#pragma once

#include "../codecs/telar_value_codec.hpp"

namespace telar {

  enum class CellWidth : Byte { continuation = 0, single = 1, wide = 2 };
  enum class UnderlineStyle : Byte { none, single, double_line, curly, dotted, dashed };
  enum class CellAttribute : std::uint16_t {
    bold = 1,
    italic = 2,
    faint = 4,
    blink = 8,
    inverse = 16,
    invisible = 32,
    strikethrough = 64,
    overline = 128
  };

  struct CellColor {
    enum class Kind : Byte { default_color, indexed, rgb };
    Kind kind = Kind::default_color;
    std::array<Byte, 3> channels{};
    bool operator==(const CellColor &other) const {
      if (kind != other.kind) {
        return false;
      }
      return kind == Kind::default_color ||
             (kind == Kind::indexed ? channels[0] == other.channels[0]
                                    : channels == other.channels);
    }
  };

  struct CellStyle {
    std::uint16_t flags = 0;
    CellColor foreground{}, background{}, underline_color{};
    bool operator==(const CellStyle &) const = default;
    void validate() const {
      if ((flags & 0xf800) != 0 || ((flags >> 8) & 7) > 5) {
        throw EncodingError{"Invalid cell style"};
      }
    }
  };

  struct Cell {
    CellWidth width = CellWidth::single;
    CellStyle style{};
    std::span<const Byte> text{};
    void validate() const {
      const auto raw_width = static_cast<Byte>(width);
      if (raw_width > 2 || text.size() > 16 || (raw_width == 0 ? !text.empty() : text.empty())) {
        throw EncodingError{"Invalid terminal cell"};
      }
      style.validate();
    }
  };

  template <> struct BodySchema<CellColor> {
    static constexpr bool fixed_size = false;
    static constexpr std::size_t min_width = 1;
    static std::size_t encodedSize(const CellColor &value) {
      EnumByte<CellColor::Kind, 2>::validate(value.kind);
      return value.kind == CellColor::Kind::default_color ? 1
             : value.kind == CellColor::Kind::indexed     ? 2
                                                          : 4;
    }
    static void encodeBody(const CellColor &value, std::span<Byte> &output) {
      const auto size = encodedSize(value);
      EnumByte<CellColor::Kind, 2>::encode(value.kind, output);
      for (std::size_t i = 0; i < size - 1; ++i) {
        u8::encode(value.channels[i], output);
      }
    }
    static void decodeBody(std::span<const Byte> &input, CellColor &value, DecodeStorage &) {
      value.kind = EnumByte<CellColor::Kind, 2>::decode(input);
      for (std::size_t i = 0; i < encodedSize(value) - 1; ++i) {
        value.channels[i] = u8::decode(input);
      }
    }
  };

  template <>
  struct BodySchema<CellStyle>
      : Serializer<Field<&CellStyle::flags, u16, "flags">,
                   Field<&CellStyle::foreground, ValueCodec<CellColor>, "foreground">,
                   Field<&CellStyle::background, ValueCodec<CellColor>, "background">,
                   Field<&CellStyle::underline_color, ValueCodec<CellColor>, "underline_color">> {
    static void validate(const CellStyle &value) { value.validate(); }
  };

} // namespace telar
