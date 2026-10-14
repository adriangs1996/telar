#pragma once

#include "../codecs/telar_cells.hpp"
#include "telar_messages.hpp"

namespace telar {

  enum class CursorShape : Byte { default_shape, block, bar, underline, hollow };
  enum class MouseTracking : Byte { none, x10, normal, button, any };
  enum class MetadataStatus : Byte { complete, omitted, partial };
  enum class RowFlag : Byte { wrap = 1, continuation = 2, wide_padding = 4, hyperlinks = 8 };
  enum class PointerShape : Byte {
    default_shape,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    all_scroll,
    col_resize,
    row_resize,
    n_resize,
    e_resize,
    s_resize,
    w_resize,
    ne_resize,
    nw_resize,
    se_resize,
    sw_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    zoom_in,
    zoom_out
  };

  struct Cursor {
    bool visible = false;
    std::uint16_t x = 0, y = 0;
    CursorShape shape = CursorShape::default_shape;
    bool blink = true;
  };
  struct Mouse {
    MouseTracking tracking{};
    bool sgr = false, pixels = false;
  };
  struct InputModes {
    bool cursor_keys = false, keypad_keys = false, bracketed_paste = false;
    bool focus_events = false, alternate_scroll = false, alternate_screen = false;
    Byte kitty_keyboard_flags = 0;
    bool modify_other_keys_2 = false;
  };
  struct Scroll {
    std::uint32_t total_rows = 0, offset = 0;
  };
  struct MetadataLink {
    std::uint32_t offset = 0;
    std::uint16_t len = 0;
  };
  struct MetadataRun {
    std::uint32_t start = 0, len = 0;
    std::uint16_t link_index = 0;
  };

  struct TextMetadata {
    MetadataStatus status{};
    std::span<const Byte> row_flags{};
    std::span<const MetadataLink> links{};
    std::span<const MetadataRun> runs{};
    std::span<const Byte> uris{};

    void validate(std::uint16_t cols, std::uint16_t rows) const {
      EnumByte<MetadataStatus, 2>::validate(status);
      if (row_flags.size() != rows || links.size() > 256 || runs.size() > 2048 ||
          uris.size() > 65536 ||
          (status == MetadataStatus::omitted &&
           (!links.empty() || !runs.empty() || !uris.empty()))) {
        throw EncodingError{"Invalid text metadata counts"};
      }
      for (const auto flags : row_flags) {
        if ((flags & 0xf0) != 0 || ((flags & 4) != 0 && ((flags & 1) == 0 || cols < 2))) {
          throw EncodingError{"Invalid text row flags"};
        }
      }
      std::size_t uri_end = 0;
      for (const auto &link : links) {
        if (link.offset != uri_end || link.len == 0 || link.len > 4096 ||
            link.len > uris.size() - uri_end) {
          throw EncodingError{"Invalid metadata link"};
        }
        uri_end += link.len;
      }
      if (uri_end != uris.size()) {
        throw EncodingError{"Unreferenced URI bytes"};
      }
      std::uint64_t previous_end = 0;
      const auto cells = static_cast<std::uint32_t>(cols) * rows;
      for (const auto &run : runs) {
        const auto end = static_cast<std::uint64_t>(run.start) + run.len;
        if (cols == 0 || run.len == 0 || run.start < previous_end || end > cells ||
            run.link_index >= links.size() || run.start / cols != (end - 1) / cols) {
          throw EncodingError{"Invalid hyperlink run"};
        }
        previous_end = end;
      }
    }

    std::span<const Byte> link(std::size_t index) const {
      if (index >= links.size()) {
        throw EncodingError{"Invalid hyperlink index"};
      }
      const auto &entry = links[index];
      if (entry.offset > uris.size() || entry.len > uris.size() - entry.offset) {
        throw EncodingError{"Invalid hyperlink bounds"};
      }
      return uris.subspan(entry.offset, entry.len);
    }
  };

  template <>
  struct BodySchema<MetadataLink> : Serializer<Field<&MetadataLink::offset, u32, "offset">,
                                               Field<&MetadataLink::len, u16, "len">> {};
  template <>
  struct BodySchema<MetadataRun>
      : Serializer<Field<&MetadataRun::start, u32, "start">, Field<&MetadataRun::len, u32, "len">,
                   Field<&MetadataRun::link_index, u16, "link_index">> {};

  // All four counts precede the row, link, run and URI arrays.
  template <> struct BodySchema<TextMetadata> {
    static constexpr bool fixed_size = false;
    static constexpr std::size_t min_width = 11;
    static std::size_t encodedSize(const TextMetadata &value) {
      if (value.row_flags.size() > 65535 || value.links.size() > 256 || value.runs.size() > 2048 ||
          value.uris.size() > 65536) {
        throw EncodingError{"Text metadata exceeds capacity"};
      }
      return 11 + value.row_flags.size() + value.links.size() * 6 + value.runs.size() * 10 +
             value.uris.size();
    }
    static void encodeBody(const TextMetadata &value, std::span<Byte> &output) {
      (void)encodedSize(value);
      EnumByte<MetadataStatus, 2>::encode(value.status, output);
      u16::encode(static_cast<std::uint16_t>(value.row_flags.size()), output);
      u16::encode(static_cast<std::uint16_t>(value.links.size()), output);
      u16::encode(static_cast<std::uint16_t>(value.runs.size()), output);
      u32::encode(static_cast<std::uint32_t>(value.uris.size()), output);
      TailBytes<65535>::encode(value.row_flags, output);
      for (const auto &link : value.links) {
        ValueCodec<MetadataLink>::encode(link, output);
      }
      for (const auto &run : value.runs) {
        ValueCodec<MetadataRun>::encode(run, output);
      }
      TailBytes<65536>::encode(value.uris, output);
    }
    static void decodeBody(std::span<const Byte> &input, TextMetadata &value,
                           DecodeStorage &storage) {
      value.status = EnumByte<MetadataStatus, 2>::decode(input);
      const auto rows = u16::decode(input);
      const auto links = u16::decode(input);
      const auto runs = u16::decode(input);
      const auto uri_length = u32::decode(input);
      if (links > 256 || runs > 2048 || uri_length > 65536 ||
          rows + static_cast<std::size_t>(links) * 6 + static_cast<std::size_t>(runs) * 10 +
                  uri_length >
              input.size()) {
        throw EncodingError{"Invalid text metadata lengths"};
      }
      value.row_flags = input.first(rows);
      input = input.subspan(rows);
      auto link_storage = storage.allocate<MetadataLink>(links);
      auto run_storage = storage.allocate<MetadataRun>(runs);
      for (auto &link : link_storage) {
        link = ValueCodec<MetadataLink>::decode(input, storage);
      }
      for (auto &run : run_storage) {
        run = ValueCodec<MetadataRun>::decode(input, storage);
      }
      value.links = link_storage;
      value.runs = run_storage;
      value.uris = input.first(uri_length);
      input = input.subspan(uri_length);
    }

    template <typename Visitor>
    static void visitFields(const TextMetadata &value, std::span<const Byte> &input,
                            Visitor visitor) {
      const auto take = [&](std::size_t size) {
        const auto bytes = input.first(size);
        input = input.subspan(size);
        return bytes;
      };
      visitor("status", take(1), value.status);
      visitor("row_count", take(2), value.row_flags.size());
      visitor("link_count", take(2), value.links.size());
      visitor("run_count", take(2), value.runs.size());
      visitor("uri_length", take(4), value.uris.size());
      visitor("row_flags", take(value.row_flags.size()), value.row_flags);
      visitor("links", take(value.links.size() * 6), value.links);
      visitor("runs", take(value.runs.size() * 10), value.runs);
      visitor("uris", take(value.uris.size()), value.uris);
    }
  };

  struct FrameMetadataCodec {
    using value_type = std::optional<TextMetadata>;
    static constexpr std::size_t min_width = 4;
    static std::size_t encodedSize(const value_type &value) {
      return value ? 4 + BodySchema<TextMetadata>::encodedSize(*value) : 4;
    }
    static void encode(const value_type &value, std::span<Byte> &output) {
      u32::encode(static_cast<std::uint32_t>(encodedSize(value) - 4), output);
      if (value) {
        ValueCodec<TextMetadata>::encode(*value, output);
      }
    }
    static value_type decode(std::span<const Byte> &input, DecodeStorage &storage) {
      const auto length = u32::decode(input);
      if (length == 0) {
        return std::nullopt;
      }
      if (length > 153098 || length > input.size()) {
        throw EncodingError{"Invalid frame metadata length"};
      }
      auto body = input.first(length);
      auto value = ValueCodec<TextMetadata>::decode(body, storage);
      if (!body.empty()) {
        throw EncodingError{"Trailing metadata bytes"};
      }
      input = input.subspan(length);
      return value;
    }
  };

  struct FrameSpan {
    std::uint32_t start = 0, count = 0;
    std::span<const Byte> cells{};
    CellReader reader() const { return CellReader{cells, count}; }
  };
  template <>
  struct BodySchema<FrameSpan>
      : Serializer<Field<&FrameSpan::start, u32, "start">,
                   Field<&FrameSpan::count, BoundedInteger<u32, 1>, "count">,
                   Field<&FrameSpan::cells, SizedBytes<u32, max_payload_size>, "cells">> {};

  struct FrameBody {
    std::uint64_t pane_id = 0, frame_id = 0, base_frame_id = 0;
    std::uint16_t cols = 0, rows = 0;
    Cursor cursor{};
    Mouse mouse{};
    InputModes input_modes{};
    PointerShape pointer_shape{};
    Scroll scroll{};
    std::optional<TextMetadata> text_metadata{};
    std::span<const FrameSpan> spans{};

    void validate() const {
      const auto cells = static_cast<std::uint32_t>(cols) * rows;
      if (pane_id == 0 || frame_id == 0 || base_frame_id >= frame_id || cols == 0 || rows == 0 ||
          cells > 130359 || spans.size() > 4096) {
        throw EncodingError{"Invalid frame header"};
      }
      if ((cursor.visible && (cursor.x >= cols || cursor.y >= rows)) ||
          (!cursor.visible && (cursor.x != 0 || cursor.y != 0)) || scroll.total_rows < rows ||
          scroll.offset > scroll.total_rows - rows) {
        throw EncodingError{"Invalid cursor or scroll"};
      }
      std::uint64_t previous_end = 0;
      for (const auto &span : spans) {
        const auto end = static_cast<std::uint64_t>(span.start) + span.count;
        if (span.count == 0 || span.start < previous_end || end > cells ||
            span.cells.size() < span.count) {
          throw EncodingError{"Invalid frame span"};
        }
        previous_end = end;
      }
      if (base_frame_id == 0 &&
          (!text_metadata || spans.size() != 1 || spans[0].start != 0 || spans[0].count != cells)) {
        throw EncodingError{"Invalid screen snapshot"};
      }
      if (text_metadata) {
        text_metadata->validate(cols, rows);
      }
    }
  };

  using FrameSerializer = Serializer<
      Field<&FrameBody::pane_id, NonzeroU64, "pane_id">,
      Field<&FrameBody::frame_id, u64, "frame_id">,
      Field<&FrameBody::base_frame_id, u64, "base_frame_id">, Field<&FrameBody::cols, u16, "cols">,
      Field<&FrameBody::rows, u16, "rows">,
      Field<[](auto &frame) -> auto & { return frame.cursor.visible; }, BoolByte, "cursor.visible">,
      Field<[](auto &frame) -> auto & { return frame.cursor.x; }, u16, "cursor.x">,
      Field<[](auto &frame) -> auto & { return frame.cursor.y; }, u16, "cursor.y">,
      Field<[](auto &frame) -> auto & { return frame.mouse.tracking; }, EnumByte<MouseTracking, 4>,
            "mouse.tracking">,
      Field<[](auto &frame) -> auto & { return frame.mouse.sgr; }, BoolByte, "mouse.sgr">,
      Field<[](auto &frame) -> auto & { return frame.mouse.pixels; }, BoolByte, "mouse.pixels">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.cursor_keys; }, BoolByte,
            "input_modes.cursor_keys">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.keypad_keys; }, BoolByte,
            "input_modes.keypad_keys">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.bracketed_paste; }, BoolByte,
            "input_modes.bracketed_paste">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.focus_events; }, BoolByte,
            "input_modes.focus_events">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.alternate_scroll; }, BoolByte,
            "input_modes.alternate_scroll">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.alternate_screen; }, BoolByte,
            "input_modes.alternate_screen">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.kitty_keyboard_flags; },
            BoundedInteger<u8, 0, 31>, "input_modes.kitty_keyboard_flags">,
      Field<[](auto &frame) -> auto & { return frame.input_modes.modify_other_keys_2; }, BoolByte,
            "input_modes.modify_other_keys_2">,
      Field<&FrameBody::pointer_shape, EnumByte<PointerShape, 33>, "pointer_shape">,
      Field<[](auto &frame) -> auto & { return frame.scroll.total_rows; }, u32,
            "scroll.total_rows">,
      Field<[](auto &frame) -> auto & { return frame.scroll.offset; }, u32, "scroll.offset">,
      SpanCountField<&FrameBody::spans, u16, ValueCodec<FrameSpan>, 4096, "span_count">,
      Field<[](auto &frame) -> auto & { return frame.cursor.shape; }, EnumByte<CursorShape, 4>,
            "cursor.shape">,
      Field<[](auto &frame) -> auto & { return frame.cursor.blink; }, BoolByte, "cursor.blink">,
      Field<&FrameBody::text_metadata, FrameMetadataCodec, "text_metadata">,
      SpanItemsField<&FrameBody::spans, ValueCodec<FrameSpan>, "spans">>;

  template <> struct BodySchema<FrameBody> : FrameSerializer {
    static void validate(const FrameBody &frame) { frame.validate(); }

    template <typename Frame> static void encodeBody(const Frame &frame, std::span<Byte> &output) {
      for (const auto &span : frame.spans) {
        auto reader = span.reader();
        while (reader.next()) {
        }
      }
      FrameSerializer::encodeBody(frame, output);
    }
  };

  struct PaneFrame : FrameBody {};
  template <>
  struct MessageSchema<PaneFrame>
      : MessageLayout<Direction::server, ServerTag::pane_frame, BodySchema<FrameBody>> {};

} // namespace telar
