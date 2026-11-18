export module telar.wire.content;

// Reading and searching what a pane shows: text, rows, documents, blocks and
// scrollback.

import std;
import telar.wire.vocabulary;
import telar.base.ds;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
export extern "C++" {
  namespace telar {

    struct ReadPane {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t pane_generation{};
      std::uint16_t rows{};
      PaneTextSource source{};
    };

    template <>
    struct MessageSchema<ReadPane>
        : Schema<Direction::client, ClientTag::read_pane, Field<&ReadPane::request_id, NonzeroU64, "request_id">, Field<&ReadPane::pane_id, NonzeroU64, "pane_id">, Field<&ReadPane::pane_generation, u64, "pane_generation">, Field<&ReadPane::rows, BoundedInteger<u16, 1, 2000>, "rows">, Field<&ReadPane::source, EnumByte<PaneTextSource, 1>, "source">> {};

    struct SearchPane {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::string_view needle{};
    };

    template <>
    struct MessageSchema<SearchPane>
        : Schema<Direction::client, ClientTag::search_pane, Field<&SearchPane::request_id, NonzeroU64, "request_id">, Field<&SearchPane::pane_id, NonzeroU64, "pane_id">, Field<&SearchPane::needle, Text16<128, false>, "needle">> {};

    // A search of the rows from `first_row` to `last_row`, counted from the scrollback's current
    // top as `PaneMatch::y` is: one command's output, say. Answered by `PaneMatches`.
    struct SearchPaneRows {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::string_view needle{};
      std::uint32_t first_row{};
      std::uint32_t last_row{};

      void validate() const;
    };

    template <>
    struct MessageSchema<SearchPaneRows>
        : Schema<Direction::client, ClientTag::search_pane_rows, Field<&SearchPaneRows::request_id, NonzeroU64, "request_id">, Field<&SearchPaneRows::pane_id, NonzeroU64, "pane_id">, Field<&SearchPaneRows::needle, Text16<128, false>, "needle">, Field<&SearchPaneRows::first_row, u32, "first_row">, Field<&SearchPaneRows::last_row, u32, "last_row">> {};

    // Rows of a pane's scrollback, by their stable number: the rows the scrollback dropped from
    // its top since the pane began (`PaneScrollback::trimmed`) plus the row counted from its
    // current top. Answered by `PaneRows`, with at most `count` rows.
    struct ReadPaneRows {
      static constexpr std::uint16_t maximum_rows = 512;

      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t from{};
      std::uint16_t count{};
    };

    template <>
    struct MessageSchema<ReadPaneRows>
        : Schema<Direction::client, ClientTag::read_pane_rows, Field<&ReadPaneRows::request_id, NonzeroU64, "request_id">, Field<&ReadPaneRows::pane_id, NonzeroU64, "pane_id">, Field<&ReadPaneRows::from, u64, "from">, Field<&ReadPaneRows::count, BoundedInteger<u16, 1, ReadPaneRows::maximum_rows>, "count">> {};

    struct PaneText {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      bool truncated{};
      std::string_view text{};
      ds::Option<std::int32_t> exit_code{};
    };

    template <>
    struct MessageSchema<PaneText>
        : Schema<Direction::server, ServerTag::pane_text, Field<&PaneText::request_id, NonzeroU64, "request_id">, Field<&PaneText::pane_id, NonzeroU64, "pane_id">, Field<&PaneText::truncated, BoolByte, "truncated">, Field<&PaneText::text, SizedText<u32, 262144, true, TextRule::opaque>, "text">, Field<&PaneText::exit_code, OptionalValue<i32>, "exit_code">> {};

    struct PaneMatches {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      bool truncated{};
      std::span<const PaneMatch> matches{};
    };

    template <>
    struct MessageSchema<PaneMatches>
        : Schema<Direction::server, ServerTag::pane_matches, Field<&PaneMatches::request_id, NonzeroU64, "request_id">, Field<&PaneMatches::pane_id, NonzeroU64, "pane_id">, Field<&PaneMatches::truncated, BoolByte, "truncated">, SpanCountField<&PaneMatches::matches, u16, ValueCodec<PaneMatch>, 256, "match_count", 0>, SpanItemsField<&PaneMatches::matches, ValueCodec<PaneMatch>, "matches">> {};

    // The commands a pane's integrated shell ran, oldest first, at most `capacity`. Sent again
    // whenever one starts or ends, or the rows they take move.
    struct PaneBlocks {
      static constexpr std::size_t capacity = 64;

      std::uint64_t pane_id{};
      std::span<const CommandBlock> blocks{};
    };

    template <>
    struct MessageSchema<PaneBlocks>
        : Schema<Direction::server, ServerTag::pane_blocks, Field<&PaneBlocks::pane_id, NonzeroU64, "pane_id">, SpanCountField<&PaneBlocks::blocks, u16, ValueCodec<CommandBlock>, PaneBlocks::capacity, "block_count", 0>, SpanItemsField<&PaneBlocks::blocks, ValueCodec<CommandBlock>, "blocks">> {};

    // How a pane's scrollback numbers its rows: `trimmed` rows dropped from its top since the
    // pane began, and a `generation` that changes when rows were renumbered some other way (a
    // reflow, an erased scrollback). A row's stable number is `trimmed` plus its current row; it
    // names the same row for as long as the generation holds. Sent when either changes.
    struct PaneScrollback {
      std::uint64_t pane_id{};
      std::uint64_t generation{};
      std::uint64_t trimmed{};
    };

    template <>
    struct MessageSchema<PaneScrollback>
        : Schema<Direction::server, ServerTag::pane_scrollback, Field<&PaneScrollback::pane_id, NonzeroU64, "pane_id">, Field<&PaneScrollback::generation, u64, "generation">, Field<&PaneScrollback::trimmed, u64, "trimmed">> {};

    // A part of a document a pane's program shows natively (`telar render`), encoded as
    // telar.render.document encodes it. Document 0 covers the pane while its program is on the
    // alternate screen; any other stands for `rows` rows of the scrollback from stable row
    // `first_row`, numbered as `generation` numbers them (see `PaneScrollback`).
    //
    // `revision` names one version of a document: a client keeps the bytes of the latest, sent
    // in order from `offset` 0, and has it whole once `offset + bytes` reaches `size`. A part
    // with no bytes at `offset == size` only moves a whole document's rows. Size 0 withdraws it.
    struct PaneDocument {
      // Limit render.max_document_bytes, as telar.render.document sets it.
      static constexpr std::uint32_t max_size = std::uint32_t{6000} * 1024;
      // Small enough that a part never holds a pane's frames back for long.
      static constexpr std::uint32_t chunk_bytes = std::uint32_t{64} << 10;

      std::uint64_t pane_id{};
      std::uint64_t id{};
      std::uint64_t revision{};
      std::uint64_t generation{};
      std::uint64_t first_row{};
      std::uint32_t rows{};
      std::uint32_t size{};
      std::uint32_t offset{};
      std::span<const Byte> bytes{};

      void validate() const;
    };

    template <>
    struct MessageSchema<PaneDocument>
        : Schema<Direction::server, ServerTag::pane_document, Field<&PaneDocument::pane_id, NonzeroU64, "pane_id">, Field<&PaneDocument::id, u64, "id">, Field<&PaneDocument::revision, u64, "revision">, Field<&PaneDocument::generation, u64, "generation">, Field<&PaneDocument::first_row, u64, "first_row">, Field<&PaneDocument::rows, u32, "rows">, Field<&PaneDocument::size, u32, "size">, Field<&PaneDocument::offset, u32, "offset">, Field<&PaneDocument::bytes, SizedBytes<u32, PaneDocument::chunk_bytes, 0>, "bytes">> {};

    // The rows a `ReadPaneRows` asked for, from stable row `from`: `rows` rows of `cols` cells,
    // encoded as a frame's, with their flags and links. No rows when none of them are retained.
    struct PaneRows {
      std::uint64_t request_id{};
      std::uint64_t pane_id{};
      std::uint64_t generation{};
      std::uint64_t trimmed{};
      std::uint64_t from{};
      std::uint16_t cols{};
      std::uint16_t rows{};
      ds::Option<TextMetadata> text_metadata{};
      std::span<const Byte> cells{};

      // A reader over the message's cells, which borrows them.
      [[nodiscard]] CellReader reader() const;

      void validate() const;
    };

    template <>
    struct MessageSchema<PaneRows>
        : Schema<Direction::server, ServerTag::pane_rows, Field<&PaneRows::request_id, NonzeroU64, "request_id">, Field<&PaneRows::pane_id, NonzeroU64, "pane_id">, Field<&PaneRows::generation, u64, "generation">, Field<&PaneRows::trimmed, u64, "trimmed">, Field<&PaneRows::from, u64, "from">, Field<&PaneRows::cols, u16, "cols">, Field<&PaneRows::rows, u16, "rows">, Field<&PaneRows::text_metadata, FrameMetadataCodec, "text_metadata">, Field<&PaneRows::cells, SizedBytes<u32, max_payload_size>, "cells">> {};

  }
}
