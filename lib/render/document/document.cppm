module;
#include "tbc/hot_path.hpp"
#include "telar_render/sequence.hpp"

export module telar.render.document;

import std;
export import telar.base.memory.allocators;
import telar.base.text;
import telar.base.text.utf8;

// A rendered document: what every renderer produces and what a client draws.
// Containers (quotes, lists, callouts) are flattened into the decorations of
// the leaf blocks they hold, so a client lays out one block after another in
// reading order without a tree walk.
export namespace telar::render {

  using telar::render::max_document_bytes;
  using telar::render::max_pane_document_bytes;
  using telar::render::max_pane_documents;
  using telar::render::max_sequence_body;
  using telar::render::sequence_begin;
  using telar::render::sequence_end;
  using telar::render::sequence_number;
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

  // A data type: its accessors are one-line views that a client reads for every block it draws,
  // and it takes whatever allocator the client's documents live in, so it stays here whole.
  template <Allocator Memory>
  struct TBC_HOT_PATH Document {
    explicit Document(Memory& memory)
        : blocks(AllocatorRef<Block, Memory>{memory}),
          cells(AllocatorRef<Cell, Memory>{memory}),
          runs(AllocatorRef<Run, Memory>{memory}),
          text(AllocatorRef<char, Memory>{memory}) {}

    [[nodiscard]] std::string_view view(Span span) const noexcept {
      return std::string_view{text}.substr(span.offset, span.size);
    }

    [[nodiscard]] std::span<const Run> runsOf(const Block& block) const noexcept {
      return std::span<const Run>{runs}.subspan(block.first, block.count);
    }

    [[nodiscard]] std::span<const Run> runsOf(const Cell& cell) const noexcept {
      return std::span<const Run>{runs}.subspan(cell.first, cell.count);
    }

    [[nodiscard]] std::span<const Cell> cellsOf(const Block& block) const noexcept {
      return std::span<const Cell>{cells}.subspan(block.first, block.count);
    }

    void clear() noexcept {
      blocks.clear();
      cells.clear();
      runs.clear();
      text.clear();
    }

    Vector<Block, Memory> blocks;
    Vector<Cell, Memory> cells;
    Vector<Run, Memory> runs;
    String<Memory> text;
  };

  // Encoding, little endian, fixed records in this order:
  //   header  "TRDC" u16 version u16 0, u32 blocks, u32 cells, u32 runs, u32 text bytes
  //   blocks  u8 kind level quote list marker callout flags 0, u16 columns u16 0,
  //           u32 number first count, u32 info offset, u32 info size
  //   cells   u32 first count, u8 align, 3 zero bytes
  //   runs    u32 text offset size, u32 target offset size, u16 style u16 0
  //   text    UTF-8
  inline constexpr std::array<std::uint8_t, 4> magic{'T', 'R', 'D', 'C'};
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
  // Generic over the caller's allocator, as Document is; the work is detail's.
  template <Allocator Memory>
  [[nodiscard]] TBC_HOT_PATH std::optional<std::size_t> encodedSize(const Document<Memory>& document) noexcept {
    const auto size = detail::encodedSize(document.blocks.size(), document.cells.size(), document.runs.size(), document.text.size());

    return size <= max_document_bytes ? std::optional<std::size_t>{static_cast<std::size_t>(size)} : std::nullopt;
  }

  // Writes exactly encodedSize(document) bytes into output.
  template <Allocator Memory>
  TBC_HOT_PATH void encode(const Document<Memory>& document, std::span<std::uint8_t> output) noexcept {
    detail::encode(document.blocks, document.cells, document.runs, document.text, output);
  }

  // Appends the OSC that begins document, or returns false when the document
  // exceeds max_document_bytes. On the primary screen, appendEnd closes it.
  template <Allocator Memory, Allocator Output>
  [[nodiscard]] bool appendSequence(const Document<Memory>& document, String<Output>& output);

  // Appends the OSC that ends the zone a document stands for.
  template <Allocator Output>
  void appendEnd(String<Output>& output);

  extern template bool appendSequence(const Document<Memory>& document, String<Memory>& output);
  extern template void appendEnd(String<Memory>& output);

  // Replaces document with the one input encodes. Input comes from any program
  // in a pane, so every count, range, enumeration and reserved byte is checked;
  // on failure the document is left empty. Generic over the caller's allocator,
  // it only sizes the document; detail reads and checks each part.
  template <Allocator Memory>
  [[nodiscard]] TBC_HOT_PATH DecodeError decode(std::span<const std::uint8_t> input, Document<Memory>& document) {
    document.clear();
    detail::Counts counts;

    auto error = detail::decodeHeader(input, counts);
    if (error != DecodeError::none) {
      return error;
    }

    document.blocks.resize(counts.blocks);
    error = detail::decodeBlocks(input, document.blocks);
    if (error == DecodeError::none) {
      document.cells.resize(counts.cells);
      error = detail::decodeCells(input, counts, document.cells);
    }

    if (error == DecodeError::none) {
      document.runs.resize(counts.runs);
      error = detail::decodeRuns(input, counts, document.runs);
    }

    if (error == DecodeError::none) {
      error = detail::checkBlocks(input, counts, document.blocks);
    }

    if (error != DecodeError::none) {
      document.clear();
      return error;
    }

    document.text.assign(detail::text(input, counts));
    return DecodeError::none;
  }

}
