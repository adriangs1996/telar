module;
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

  template <Allocator Memory>
  struct Document {
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
    inline std::uint64_t encodedSize(std::uint64_t blocks, std::uint64_t cells, std::uint64_t runs, std::uint64_t text) noexcept {
      return header_bytes + blocks * block_bytes + cells * cell_bytes + runs * run_bytes + text;
    }

    class Writer {
    public:
      explicit Writer(std::span<std::uint8_t> output) noexcept
          : output_(output) {}

      void u8(std::uint8_t value) noexcept {
        output_[at_++] = value;
      }

      void u16(std::uint16_t value) noexcept {
        u8(static_cast<std::uint8_t>(value));
        u8(static_cast<std::uint8_t>(value >> 8));
      }

      void u32(std::uint32_t value) noexcept {
        u16(static_cast<std::uint16_t>(value));
        u16(static_cast<std::uint16_t>(value >> 16));
      }

      void bytes(std::string_view value) noexcept {
        std::memcpy(output_.data() + at_, value.data(), value.size());
        at_ += value.size();
      }

    private:
      std::span<std::uint8_t> output_;
      std::size_t at_ = 0;
    };

    // Reads records the caller already proved to be in bounds.
    class Reader {
    public:
      explicit Reader(std::span<const std::uint8_t> input) noexcept
          : input_(input) {}

      std::uint8_t u8() noexcept {
        return input_[at_++];
      }

      std::uint16_t u16() noexcept {
        const auto low = u8();

        return static_cast<std::uint16_t>(low | (u8() << 8));
      }

      std::uint32_t u32() noexcept {
        const auto low = u16();

        return low | (static_cast<std::uint32_t>(u16()) << 16);
      }

      [[nodiscard]] std::size_t at() const noexcept {
        return at_;
      }

    private:
      std::span<const std::uint8_t> input_;
      std::size_t at_ = 0;
    };

    inline bool within(std::uint32_t first, std::uint32_t count, std::size_t size) noexcept {
      return first <= size && count <= size - first;
    }

    inline bool boundary(std::string_view text, std::size_t at) noexcept {
      return at == text.size() || (static_cast<std::uint8_t>(text[at]) & 0xc0) != 0x80;
    }

    inline bool validSpan(std::string_view text, Span span) noexcept {
      return within(span.offset, span.size, text.size()) && boundary(text, span.offset) && boundary(text, span.offset + span.size);
    }
  }

  // The encoded size, or nothing when the document exceeds max_document_bytes.
  template <Allocator Memory>
  [[nodiscard]] std::optional<std::size_t> encodedSize(const Document<Memory>& document) noexcept {
    const auto size = detail::encodedSize(document.blocks.size(), document.cells.size(), document.runs.size(), document.text.size());

    return size <= max_document_bytes ? std::optional<std::size_t>{static_cast<std::size_t>(size)} : std::nullopt;
  }

  // Writes exactly encodedSize(document) bytes into output.
  template <Allocator Memory>
  void encode(const Document<Memory>& document, std::span<std::uint8_t> output) noexcept {
    detail::Writer writer{output};

    for (const auto byte : magic) {
      writer.u8(byte);
    }

    writer.u16(version);
    writer.u16(0);
    writer.u32(static_cast<std::uint32_t>(document.blocks.size()));
    writer.u32(static_cast<std::uint32_t>(document.cells.size()));
    writer.u32(static_cast<std::uint32_t>(document.runs.size()));
    writer.u32(static_cast<std::uint32_t>(document.text.size()));
    for (const auto& block : document.blocks) {
      writer.u8(static_cast<std::uint8_t>(block.kind));
      writer.u8(block.level);
      writer.u8(block.quote);
      writer.u8(block.list);
      writer.u8(static_cast<std::uint8_t>(block.marker));
      writer.u8(static_cast<std::uint8_t>(block.callout));
      writer.u8(block.flags);
      writer.u8(0);
      writer.u16(block.columns);
      writer.u16(0);
      writer.u32(block.number);
      writer.u32(block.first);
      writer.u32(block.count);
      writer.u32(block.info.offset);
      writer.u32(block.info.size);
    }

    for (const auto& cell : document.cells) {
      writer.u32(cell.first);
      writer.u32(cell.count);
      writer.u8(static_cast<std::uint8_t>(cell.align));
      writer.u8(0);
      writer.u16(0);
    }

    for (const auto& run : document.runs) {
      writer.u32(run.text.offset);
      writer.u32(run.text.size);
      writer.u32(run.target.offset);
      writer.u32(run.target.size);
      writer.u16(run.style);
      writer.u16(0);
    }

    writer.bytes(document.text);
  }

  // Appends the OSC that begins document, or returns false when the document
  // exceeds max_document_bytes. On the primary screen, appendEnd closes it.
  template <Allocator Memory, Allocator Output>
  [[nodiscard]] bool appendSequence(const Document<Memory>& document, String<Output>& output) {
    const auto size = encodedSize(document);
    if (!size) {
      return false;
    }

    Vector<std::uint8_t, Output> bytes(*size, AllocatorRef<std::uint8_t, Output>{output.get_allocator().memory()});

    encode(document, bytes);
    const auto encoded = (*size + 2) / 3 * 4;

    output.append("\x1b]");
    output.append(sequence_begin);
    const auto body = output.size();

    output.resize(body + encoded);
    static_cast<void>(runtime::base64::encode(bytes, std::span<char>{output.data() + body, encoded}));
    output.append("\x1b\\");
    return true;
  }

  // Appends the OSC that ends the zone a document stands for.
  template <Allocator Output>
  void appendEnd(String<Output>& output) {
    output.append("\x1b]");
    output.append(sequence_end);
    output.append("\x1b\\");
  }

  // Replaces document with the one input encodes. Input comes from any program
  // in a pane, so every count, range, enumeration and reserved byte is checked;
  // on failure the document is left empty.
  template <Allocator Memory>
  [[nodiscard]] DecodeError decode(std::span<const std::uint8_t> input, Document<Memory>& document) {
    document.clear();
    if (input.size() > max_document_bytes) {
      return DecodeError::too_large;
    }

    if (input.size() < header_bytes) {
      return DecodeError::truncated;
    }

    if (!std::equal(magic.begin(), magic.end(), input.begin())) {
      return DecodeError::magic;
    }

    detail::Reader reader{input.subspan(magic.size())};
    if (reader.u16() != version) {
      return DecodeError::version;
    }

    if (reader.u16() != 0) {
      return DecodeError::malformed;
    }

    const auto block_count = reader.u32();
    const auto cell_count = reader.u32();
    const auto run_count = reader.u32();
    const auto text_size = reader.u32();
    // Each count is below 2^32 and each record below 2^6 bytes, so the sum cannot wrap.
    const auto expected = detail::encodedSize(block_count, cell_count, run_count, text_size);
    if (expected < input.size()) {
      return DecodeError::malformed;
    }

    if (expected > input.size()) {
      return DecodeError::truncated;
    }

    const auto text_bytes = input.last(text_size);
    const std::string_view text{reinterpret_cast<const char*>(text_bytes.data()), text_bytes.size()};
    if (inspectUtf8(text) != Utf8Validation::valid) {
      return DecodeError::utf8;
    }

    const auto fail = [&](DecodeError error) {
      document.clear();
      return error;
    };

    detail::Reader records{input.subspan(header_bytes)};

    document.blocks.resize(block_count);
    for (auto& block : document.blocks) {
      const auto kind = records.u8();

      block.level = records.u8();
      block.quote = records.u8();
      block.list = records.u8();
      const auto marker = records.u8();
      const auto callout = records.u8();

      block.flags = records.u8();
      const auto reserved = records.u8();

      block.columns = records.u16();
      const auto reserved_columns = records.u16();

      block.number = records.u32();
      block.first = records.u32();
      block.count = records.u32();
      block.info.offset = records.u32();
      block.info.size = records.u32();
      if (kind >= static_cast<std::uint8_t>(BlockKind::count) || marker >= static_cast<std::uint8_t>(Marker::count) || callout >= static_cast<std::uint8_t>(Callout::count) || (block.flags & ~Block::known_flags) != 0 || reserved != 0 || reserved_columns != 0 || block.quote > max_nesting || block.list > max_nesting) {
        return fail(DecodeError::malformed);
      }

      block.kind = static_cast<BlockKind>(kind);
      block.marker = static_cast<Marker>(marker);
      block.callout = static_cast<Callout>(callout);
    }

    document.cells.resize(cell_count);
    for (auto& cell : document.cells) {
      cell.first = records.u32();
      cell.count = records.u32();
      const auto align = records.u8();
      const auto reserved = records.u8();
      if (align >= static_cast<std::uint8_t>(Align::count) || reserved != 0 || records.u16() != 0) {
        return fail(DecodeError::malformed);
      }

      cell.align = static_cast<Align>(align);
      if (!detail::within(cell.first, cell.count, run_count)) {
        return fail(DecodeError::range);
      }
    }

    document.runs.resize(run_count);
    for (auto& run : document.runs) {
      run.text.offset = records.u32();
      run.text.size = records.u32();
      run.target.offset = records.u32();
      run.target.size = records.u32();
      run.style = records.u16();
      if (records.u16() != 0 || (run.style & ~style::all) != 0) {
        return fail(DecodeError::malformed);
      }

      if (!detail::validSpan(text, run.text) || !detail::validSpan(text, run.target)) {
        return fail(DecodeError::range);
      }
    }

    for (const auto& block : document.blocks) {
      const bool shape = [&] {
        switch (block.kind) {
        case BlockKind::paragraph:
          return block.level == 0 && block.columns == 0;
        case BlockKind::heading:
          return block.level >= 1 && block.level <= max_heading && block.columns == 0;
        case BlockKind::code:
        case BlockKind::html:
          return block.level == 0 && block.columns == 0;
        case BlockKind::rule:
          return block.level == 0 && block.columns == 0 && block.first == 0 && block.count == 0;
        case BlockKind::table:
          return block.level == 0 && block.columns != 0 && block.count % block.columns == 0;
        case BlockKind::count:
          break;
        }

        return false;
      }();
      if (!shape) {
        return fail(DecodeError::malformed);
      }

      const bool in_range = [&] {
        switch (block.kind) {
        case BlockKind::paragraph:
        case BlockKind::heading:
          return detail::within(block.first, block.count, run_count);
        case BlockKind::table:
          return detail::within(block.first, block.count, cell_count);
        case BlockKind::code:
        case BlockKind::html:
          return detail::validSpan(text, Span{block.first, block.count});
        default:
          return true;
        }
      }();
      if (!in_range || !detail::validSpan(text, block.info)) {
        return fail(DecodeError::range);
      }
    }

    document.text.assign(text);
    return DecodeError::none;
  }

}
