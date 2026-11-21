#pragma once

#include "../codecs/telar_value_codec.hpp"
#include "telar_base/ds/values.hpp"

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
  enum class CellAttribute : std::uint8_t {
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
    ds::Array<Byte, 3> channels{};

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
    // The flag that says the cell is of a link, above the attributes and the underline's
    // style: an editor sets it on the cells whose highlight names a URL.
    static constexpr std::uint16_t link = 1U << 11U;

    std::uint16_t flags = 0;
    CellColor foreground{};
    CellColor background{};
    CellColor underline_color{};

    bool operator==(const CellStyle&) const = default;

    void validate() const;
  };

  struct Cell {
    static constexpr std::size_t maximum_text_bytes = 16;

    CellWidth width = CellWidth::single;
    CellStyle style{};
    std::span<const Byte> text;

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
