#pragma once

#include "../serializers/telar_cells.hpp"

namespace telar {

  // Styles are inherited only within one span. Text borrows the encoded frame.
  class CellReader {
  public:
    CellReader(std::span<const Byte> bytes, std::uint32_t count) : input{bytes}, remaining{count} {}
    std::optional<Cell> next() {
      if (remaining == 0) {
        if (!input.empty()) {
          throw EncodingError{"Trailing cell bytes"};
        }
        return std::nullopt;
      }
      const auto header = u8::decode(input);
      const auto length = header & 0x1f;
      if ((header & 0x80) != 0) {
        DecodeStorage storage{};
        previous_style = ValueCodec<CellStyle>::decode(input, storage);
      } else if (!previous_style) {
        throw EncodingError{"First cell needs a style"};
      }
      if (static_cast<std::size_t>(length) > input.size()) {
        throw EncodingError{"Truncated cell text"};
      }
      Cell cell{static_cast<CellWidth>((header >> 5) & 3), *previous_style, input.first(length)};
      cell.validate();
      input = input.subspan(length);
      --remaining;
      if (remaining == 0 && !input.empty()) {
        throw EncodingError{"Trailing cell bytes"};
      }
      return cell;
    }

  private:
    std::span<const Byte> input{};
    std::uint32_t remaining = 0;
    std::optional<CellStyle> previous_style{};
  };

  struct CellRunCodec {
    static std::size_t encodedSize(std::span<const Cell> cells) {
      std::size_t size = 0;
      const CellStyle *previous = nullptr;
      for (const auto &cell : cells) {
        cell.validate();
        size = checkedWireSize(size, 1 + cell.text.size());
        if (!previous || !(*previous == cell.style)) {
          size = checkedWireSize(size, ValueCodec<CellStyle>::encodedSize(cell.style));
        }
        previous = &cell.style;
      }
      return size;
    }
    static std::span<Byte> encode(std::span<const Cell> cells, std::span<Byte> buffer) {
      const auto size = encodedSize(cells);
      if (size > buffer.size()) {
        throw EncodingError{"Cell buffer too small"};
      }
      auto output = buffer.first(size);
      const CellStyle *previous = nullptr;
      for (const auto &cell : cells) {
        const auto changed = !previous || !(*previous == cell.style);
        u8::encode(static_cast<Byte>(cell.text.size() | (static_cast<Byte>(cell.width) << 5) |
                                     (changed ? 0x80 : 0)),
                   output);
        if (changed) {
          ValueCodec<CellStyle>::encode(cell.style, output);
        }
        TailBytes<16>::encode(cell.text, output);
        previous = &cell.style;
      }
      return buffer.first(size);
    }
  };

} // namespace telar
