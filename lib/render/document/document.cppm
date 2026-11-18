export module telar.render.document;

import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.base.ds;

export namespace telar::render {

  // A program hands its pane a document with one OSC:
  //
  //   ESC ] 7780 ; begin ; <base64 of the encoding> ESC \
  //
  // On the alternate screen the document covers the pane until the program
  // leaves that screen. On the primary screen it opens a zone at the cursor's
  // row: the output that follows, up to ESC ] 7780 ; end ESC \, is the text
  // the document stands for, and a client that can draw the document shows it
  // in place of those rows.
  inline constexpr unsigned sequence_number = 7780;
  inline constexpr std::string_view sequence_begin = "7780;begin;";
  inline constexpr std::string_view sequence_end = "7780;end";

  // Limit render.max_document_bytes: the largest encoded document a renderer
  // writes and a decoder accepts. Its sequence fits the 8 MiB a terminal
  // buffers for one OSC.
  inline constexpr std::size_t max_document_bytes = std::size_t{6000} * 1024;

  // Limits render.max_pane_documents and render.max_pane_document_bytes: the
  // documents a terminal keeps for one pane's scrollback. Past either, the
  // oldest goes and its rows show their text again.
  inline constexpr std::size_t max_pane_documents = 8;
  inline constexpr std::size_t max_pane_document_bytes = std::size_t{16} << 20;

  // The longest OSC body that can carry a document.
  inline constexpr std::size_t max_sequence_body = sequence_begin.size() + (max_document_bytes + 2) / 3 * 4;
  static_assert(max_sequence_body <= std::size_t{8} << 20);

}

// A rendered document: what every renderer produces and what a client draws.
// Containers (quotes, lists, callouts) are flattened into the decorations of
// the leaf blocks they hold, so a client lays out one block after another in
// reading order without a tree walk.
export namespace telar::render {

  // Limit render.max_nesting: block quotes and list items deeper than this keep
  // the indentation of this depth.
  inline constexpr std::uint8_t max_nesting = 32;
  inline constexpr std::uint8_t max_heading = 6;

  // A byte range of Document::text.
  struct Span {
    std::uint32_t offset = 0;
    std::uint32_t size = 0;

    friend constexpr bool operator==(Span, Span) = default;
  };

  enum class BlockKind : std::uint8_t {
    paragraph, // runs
    heading,   // runs; level 1..6
    code,      // verbatim text; info is the language
    rule,
    table, // cells, row by row; the first row is the header
    html,  // verbatim raw HTML, never interpreted
    count,
  };

  // What a list item shows before its first leaf block.
  enum class Marker : std::uint8_t {
    none,
    bullet,
    ordered, // Block::number
    task_open,
    task_done,
    footnote, // Block::number
    count,
  };

  // The innermost GitHub admonition (`> [!NOTE]`) around a block.
  enum class Callout : std::uint8_t {
    none,
    note,
    tip,
    important,
    warning,
    caution,
    count,
  };

  enum class Align : std::uint8_t {
    start,
    left,
    center,
    right,
    count,
  };

  namespace style {
    inline constexpr std::uint16_t strong = 1 << 0;
    inline constexpr std::uint16_t emphasis = 1 << 1;
    inline constexpr std::uint16_t code = 1 << 2;
    inline constexpr std::uint16_t strike = 1 << 3;
    inline constexpr std::uint16_t link = 1 << 4;  // Run::target is the destination
    inline constexpr std::uint16_t image = 1 << 5; // text is the alternative text; Run::target the source, never fetched
    inline constexpr std::uint16_t math = 1 << 6;
    inline constexpr std::uint16_t html = 1 << 7; // inline raw HTML, shown verbatim
    inline constexpr std::uint16_t superscript = 1 << 8;
    inline constexpr std::uint16_t all = (1 << 9) - 1;
  }

  // Text with one style. A hard line break is a '\n' inside the text.
  struct Run {
    Span text;
    Span target;
    std::uint16_t style = 0;

    friend constexpr bool operator==(const Run&, const Run&) = default;
  };

  struct Cell {
    std::uint32_t first = 0; // first run
    std::uint32_t count = 0;
    Align align = Align::start;

    friend constexpr bool operator==(const Cell&, const Cell&) = default;
  };

  struct Block {
    static constexpr std::uint8_t tight = 1 << 0;         // inside a tight list: no gap before it
    static constexpr std::uint8_t opens_callout = 1 << 1; // the first block of its callout
    static constexpr std::uint8_t known_flags = tight | opens_callout;

    BlockKind kind = BlockKind::paragraph;
    std::uint8_t level = 0;
    std::uint8_t quote = 0; // enclosing block quotes and callouts
    std::uint8_t list = 0;  // enclosing list items
    Marker marker = Marker::none;
    Callout callout = Callout::none;
    std::uint8_t flags = 0;
    std::uint16_t columns = 0;
    std::uint32_t number = 0;
    // Runs of a paragraph or heading, cells of a table, or the text of code and html.
    std::uint32_t first = 0;
    std::uint32_t count = 0;
    Span info;

    friend constexpr bool operator==(const Block&, const Block&) = default;
  };

  // A data type over the allocator a client's documents live in; built in document.cpp for Memory.
  template <Allocator Memory>
  struct Document {
    explicit Document(Memory& memory);

    [[nodiscard]] std::string_view view(Span span) const noexcept;
    [[nodiscard]] std::span<const Run> runsOf(const Block& block) const noexcept;
    [[nodiscard]] std::span<const Run> runsOf(const Cell& cell) const noexcept;
    [[nodiscard]] std::span<const Cell> cellsOf(const Block& block) const noexcept;
    void clear() noexcept;

    ds::Vec<Block, Memory> blocks;
    ds::Vec<Cell, Memory> cells;
    ds::Vec<Run, Memory> runs;
    ds::String<Memory> text;
  };

  extern template struct Document<Memory>;

  // Encoding, little endian, fixed records in this order:
  //   header  "TRDC" u16 version u16 0, u32 blocks, u32 cells, u32 runs, u32 text bytes
  //   blocks  u8 kind level quote list marker callout flags 0, u16 columns u16 0,
  //           u32 number first count, u32 info offset, u32 info size
  //   cells   u32 first count, u8 align, 3 zero bytes
  //   runs    u32 text offset size, u32 target offset size, u16 style u16 0
  //   text    UTF-8
  inline constexpr ds::Array<std::uint8_t, 4> magic{'T', 'R', 'D', 'C'};
  inline constexpr std::uint16_t version = 1;
  inline constexpr std::size_t header_bytes = 24;
  inline constexpr std::size_t block_bytes = 32;
  inline constexpr std::size_t cell_bytes = 12;
  inline constexpr std::size_t run_bytes = 20;

  enum class DecodeError : std::uint8_t {
    none,
    truncated,
    magic,
    version,
    too_large,
    malformed,
    range,
    utf8,
  };

  namespace detail {
    constexpr std::uint64_t encodedSize(std::uint64_t blocks, std::uint64_t cells, std::uint64_t runs, std::uint64_t text) noexcept {
      return header_bytes + blocks * block_bytes + cells * cell_bytes + runs * run_bytes + text;
    }

    // The counts an encoding's header promises.
    struct Counts {
      std::uint32_t blocks = 0;
      std::uint32_t cells = 0;
      std::uint32_t runs = 0;
      std::uint32_t text = 0;
    };

    void encode(std::span<const Block> blocks, std::span<const Cell> cells, std::span<const Run> runs, std::string_view text, std::span<std::uint8_t> output) noexcept;

    // Each step of decode, in its order: the header and the text first, then each kind of record
    // as its vector is sized, and last what a block refers to.
    [[nodiscard]] DecodeError decodeHeader(std::span<const std::uint8_t> input, Counts& counts) noexcept;
    [[nodiscard]] DecodeError decodeBlocks(std::span<const std::uint8_t> input, std::span<Block> blocks) noexcept;
    [[nodiscard]] DecodeError decodeCells(std::span<const std::uint8_t> input, const Counts& counts, std::span<Cell> cells) noexcept;
    [[nodiscard]] DecodeError decodeRuns(std::span<const std::uint8_t> input, const Counts& counts, std::span<Run> runs) noexcept;
    [[nodiscard]] DecodeError checkBlocks(std::span<const std::uint8_t> input, const Counts& counts, std::span<const Block> blocks) noexcept;
    [[nodiscard]] std::string_view text(std::span<const std::uint8_t> input, const Counts& counts) noexcept;
  }

  // The encoded size, or nothing when the document exceeds max_document_bytes.
  template <Allocator Memory>
  [[nodiscard]] ds::Option<std::size_t> encodedSize(const Document<Memory>& document) noexcept;

  // Writes exactly encodedSize(document) bytes into output.
  template <Allocator Memory>
  void encode(const Document<Memory>& document, std::span<std::uint8_t> output) noexcept;

  extern template ds::Option<std::size_t> encodedSize<Memory>(const Document<Memory>& document) noexcept;
  extern template void encode<Memory>(const Document<Memory>& document, std::span<std::uint8_t> output) noexcept;

  // Appends the OSC that begins document, or returns false when the document
  // exceeds max_document_bytes. On the primary screen, appendEnd closes it.
  [[nodiscard]] bool appendSequence(const Document<Memory>& document, ds::String<Memory>& output);

  // Appends the OSC that ends the zone a document stands for.
  void appendEnd(ds::String<Memory>& output);

  // Replaces document with the one input encodes. Input comes from any program
  // in a pane, so every count, range, enumeration and reserved byte is checked;
  // on failure the document is left empty. It only sizes the document; detail
  // reads and checks each part.
  template <Allocator Memory>
  [[nodiscard]] DecodeError decode(std::span<const std::uint8_t> input, Document<Memory>& document);

  extern template DecodeError decode<Memory>(std::span<const std::uint8_t> input, Document<Memory>& document);

}
