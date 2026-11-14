#pragma once

#include "../codecs/telar_value_codec.hpp"

namespace telar {

  enum class CellWidth : Byte {
    continuation = 0,
    single = 1,
    wide = 2,
  };
  enum class UnderlineStyle : Byte {
    none,
    single,
    double_line,
    curly,
    dotted,
    dashed,
  };
  enum class CellAttribute : std::uint16_t {
    bold = 1,
    italic = 2,
    faint = 4,
    blink = 8,
    inverse = 16,
    invisible = 32,
    strikethrough = 64,
    overline = 128,
  };

  struct CellColor {
    enum class Kind : Byte {
      default_color,
      indexed,
      rgb,
    };
    Kind kind = Kind::default_color;
    std::array<Byte, 3> channels{};

    constexpr bool operator==(const CellColor& other) const {
      if (kind != other.kind) {
        return false;
      }

      return kind == Kind::default_color ||
             (kind == Kind::indexed ? channels[0] == other.channels[0]
                                    : channels == other.channels);
    }
  };

  // Every cell of a frame is validated and coded on its own; the codecs are in vocabulary.cpp.
  struct CellStyle {
    std::uint16_t flags = 0;
    CellColor foreground{}, background{}, underline_color{};
    bool operator==(const CellStyle&) const = default;

    void validate() const;
  };

  struct Cell {
    CellWidth width = CellWidth::single;
    CellStyle style{};
    std::span<const Byte> text{};

    void validate() const;
  };

  template <>
  struct BodySchema<CellColor> {
    static constexpr bool fixed_size = false;
    static constexpr std::size_t min_width = 1;

    static std::size_t encodedSize(const CellColor& value);
    static void encodeBody(const CellColor& value, std::span<Byte>& output);
    static void decodeBody(std::span<const Byte>& input, CellColor& value, DecodeStorage&);
  };

  template <>
  struct BodySchema<CellStyle>
      : Serializer<Field<&CellStyle::flags, u16, "flags">, Field<&CellStyle::foreground, ValueCodec<CellColor>, "foreground">, Field<&CellStyle::background, ValueCodec<CellColor>, "background">, Field<&CellStyle::underline_color, ValueCodec<CellColor>, "underline_color">> {
    static void validate(const CellStyle& value);
  };

} // namespace telar
