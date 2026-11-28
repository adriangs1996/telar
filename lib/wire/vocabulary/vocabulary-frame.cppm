export module telar.wire.vocabulary:frame;

export import :cells;
export import :messages;

import std;
import telar.tbc;
import telar.base.ds;

export {
  namespace telar {

    enum class CursorShape : Byte {
      default_shape,
      block,
      bar,
      underline,
      hollow,
    };
    enum class MouseTracking : Byte {
      none,
      x10,
      normal,
      button,
      any,
    };
    enum class MetadataStatus : Byte {
      complete,
      omitted,
      partial,
    };
    enum class RowFlag : Byte {
      wrap = 1,
      continuation = 2,
      wide_padding = 4,
      hyperlinks = 8,
      // The shell marked the row as the start of its prompt, or a further line of it (OSC 133).
      prompt = 16,
      prompt_continuation = 32,
    };
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
      zoom_out,
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
      bool cursor_keys = false, keypad_keys = false, bracketed_paste = false, paste_events = false;
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
      static constexpr std::size_t maximum_rows = std::numeric_limits<std::uint16_t>::max();
      static constexpr std::size_t maximum_links = 256;
      static constexpr std::size_t maximum_runs = 2048;
      static constexpr std::size_t maximum_uri_bytes = 65536;
      static constexpr std::size_t maximum_link_bytes = 4096;

      MetadataStatus status{};
      std::span<const Byte> row_flags;
      std::span<const MetadataLink> links;
      std::span<const MetadataRun> runs;
      std::span<const Byte> uris;

      void validate(std::uint16_t cols, std::uint16_t rows) const;
      [[nodiscard]] std::span<const Byte> link(std::size_t index) const;
    };

    template <>
    struct BodySchema<MetadataLink> : Serializer<Field<&MetadataLink::offset, u32, "offset">, Field<&MetadataLink::len, u16, "len">> {};

    template <>
    struct BodySchema<MetadataRun> : Serializer<Field<&MetadataRun::start, u32, "start">, Field<&MetadataRun::len, u32, "len">, Field<&MetadataRun::link_index, u16, "link_index">> {
    };

    // All four counts precede the row, link, run and URI arrays.
    template <>
    struct BodySchema<TextMetadata> {
      static constexpr bool fixed_size = false;
      static constexpr std::size_t min_width = 11;

      static std::size_t encodedSize(const TextMetadata& value);
      static void encodeBody(const TextMetadata& value, std::span<Byte>& output);
      static void decodeBody(DecodeInput input, tbc::mut_a<TextMetadata> value, DecodeStorage& storage);

      template <typename Visitor>
      [[tbc::generic]] static void
      visitFields(const TextMetadata& value, std::span<const Byte>& input, Visitor visitor) {
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
        visitor("links", take(value.links.size() * BodySchema<MetadataLink>::payload_size), value.links);
        visitor("runs", take(value.runs.size() * BodySchema<MetadataRun>::payload_size), value.runs);
        visitor("uris", take(value.uris.size()), value.uris);
      }
    };

    struct FrameMetadataCodec {
      using value_type = ds::Option<TextMetadata>;
      static constexpr std::size_t min_width = 4;
      // The largest encoded text metadata a frame carries.
      static constexpr std::size_t maximum_bytes = 153098;

      static std::size_t encodedSize(const value_type& value);
      static void encode(const value_type& value, std::span<Byte>& output);
      static Decoded<value_type> decode(DecodeInput input, DecodeStorage& storage);
    };

    struct FrameSpan {
      std::uint32_t start = 0, count = 0;
      std::span<const Byte> cells;

      [[nodiscard]] CellReader reader() const;
    };

    template <>
    struct BodySchema<FrameSpan>
        : Serializer<Field<&FrameSpan::start, u32, "start">, Field<&FrameSpan::count, BoundedInteger<u32, 1>, "count">, Field<&FrameSpan::cells, SizedBytes<u32, max_payload_size>, "cells">> {};

    struct FrameBody {
      static constexpr std::size_t maximum_spans = 4096;

      std::uint64_t pane_id = 0, frame_id = 0, base_frame_id = 0;
      std::uint16_t cols = 0, rows = 0;
      Cursor cursor{};
      Mouse mouse{};
      InputModes input_modes{};
      PointerShape pointer_shape{};
      Scroll scroll{};
      ds::Option<TextMetadata> text_metadata;
      std::span<const FrameSpan> spans;

      void validate() const;
    };

    // The Kitty keyboard protocol's five progressive enhancement flags.
    inline constexpr Byte max_kitty_keyboard_flags = 31;

    using FrameSerializer =
        Serializer<Field<&FrameBody::pane_id, NonzeroU64, "pane_id">, Field<&FrameBody::frame_id, u64, "frame_id">, Field<&FrameBody::base_frame_id, u64, "base_frame_id">, Field<&FrameBody::cols, u16, "cols">, Field<&FrameBody::rows, u16, "rows">, Field<[](auto& frame) -> auto& {
          return frame.cursor.visible;
        },
                                                                                                                                                                                                                                                            BoolByte,
                                                                                                                                                                                                                                                            "cursor.visible">,
            Field<[](auto& frame) -> auto& {
              return frame.cursor.x;
            },
                u16,
                "cursor.x">,
            Field<[](auto& frame) -> auto& {
              return frame.cursor.y;
            },
                u16,
                "cursor.y">,
            Field<[](auto& frame) -> auto& {
              return frame.mouse.tracking;
            },
                EnumByte<MouseTracking, 4>,
                "mouse.tracking">,
            Field<[](auto& frame) -> auto& {
              return frame.mouse.sgr;
            },
                BoolByte,
                "mouse.sgr">,
            Field<[](auto& frame) -> auto& {
              return frame.mouse.pixels;
            },
                BoolByte,
                "mouse.pixels">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.cursor_keys;
            },
                BoolByte,
                "input_modes.cursor_keys">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.keypad_keys;
            },
                BoolByte,
                "input_modes.keypad_keys">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.bracketed_paste;
            },
                BoolByte,
                "input_modes.bracketed_paste">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.paste_events;
            },
                BoolByte,
                "input_modes.paste_events">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.focus_events;
            },
                BoolByte,
                "input_modes.focus_events">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.alternate_scroll;
            },
                BoolByte,
                "input_modes.alternate_scroll">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.alternate_screen;
            },
                BoolByte,
                "input_modes.alternate_screen">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.kitty_keyboard_flags;
            },
                BoundedInteger<u8, 0, max_kitty_keyboard_flags>,
                "input_modes.kitty_keyboard_flags">,
            Field<[](auto& frame) -> auto& {
              return frame.input_modes.modify_other_keys_2;
            },
                BoolByte,
                "input_modes.modify_other_keys_2">,
            Field<&FrameBody::pointer_shape, EnumByte<PointerShape, std::to_underlying(PointerShape::zoom_out)>, "pointer_shape">,
            Field<[](auto& frame) -> auto& {
              return frame.scroll.total_rows;
            },
                u32,
                "scroll.total_rows">,
            Field<[](auto& frame) -> auto& {
              return frame.scroll.offset;
            },
                u32,
                "scroll.offset">,
            SpanCountField<&FrameBody::spans, u16, ValueCodec<FrameSpan>, FrameBody::maximum_spans, "span_count">,
            Field<[](auto& frame) -> auto& {
              return frame.cursor.shape;
            },
                EnumByte<CursorShape, 4>,
                "cursor.shape">,
            Field<[](auto& frame) -> auto& {
              return frame.cursor.blink;
            },
                BoolByte,
                "cursor.blink">,
            Field<&FrameBody::text_metadata, FrameMetadataCodec, "text_metadata">,
            SpanItemsField<&FrameBody::spans, ValueCodec<FrameSpan>, "spans">>;

    template <>
    struct BodySchema<FrameBody> : FrameSerializer {
      static void validate(const FrameBody& frame);

      // Generic over the frame message the caller encodes.
      template <typename Frame>
      [[tbc::generic]] static void encodeBody(const Frame& frame, std::span<Byte>& output) {
        for (const auto& span : frame.spans) {
          auto reader = span.reader();

          while (reader.next()) {
          }
        }

        FrameSerializer::encodeBody(frame, output);
      }
    };

    struct PaneFrame : FrameBody {};

  } // namespace telar
}
