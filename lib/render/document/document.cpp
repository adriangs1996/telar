module telar.render.document;

import std;
import telar.base.text;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::render {

  namespace {
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

    bool within(std::uint32_t first, std::uint32_t count, std::size_t size) noexcept {
      return first <= size && count <= size - first;
    }

    bool boundary(std::string_view text, std::size_t at) noexcept {
      return at == text.size() || (static_cast<std::uint8_t>(text[at]) & 0xc0) != 0x80;
    }

    bool validSpan(std::string_view text, Span span) noexcept {
      return within(span.offset, span.size, text.size()) && boundary(text, span.offset) && boundary(text, span.offset + span.size);
    }

  }

  namespace detail {
    void encode(std::span<const Block> blocks, std::span<const Cell> cells, std::span<const Run> runs, std::string_view text, std::span<std::uint8_t> output) noexcept {
      Writer writer{output};

      for (const auto byte : magic) {
        writer.u8(byte);
      }

      writer.u16(version);
      writer.u16(0);
      writer.u32(static_cast<std::uint32_t>(blocks.size()));
      writer.u32(static_cast<std::uint32_t>(cells.size()));
      writer.u32(static_cast<std::uint32_t>(runs.size()));
      writer.u32(static_cast<std::uint32_t>(text.size()));
      for (const auto& block : blocks) {
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

      for (const auto& cell : cells) {
        writer.u32(cell.first);
        writer.u32(cell.count);
        writer.u8(static_cast<std::uint8_t>(cell.align));
        writer.u8(0);
        writer.u16(0);
      }

      for (const auto& run : runs) {
        writer.u32(run.text.offset);
        writer.u32(run.text.size);
        writer.u32(run.target.offset);
        writer.u32(run.target.size);
        writer.u16(run.style);
        writer.u16(0);
      }

      writer.bytes(text);
    }

    DecodeError decodeHeader(std::span<const std::uint8_t> input, Counts& counts) noexcept {
      if (input.size() > max_document_bytes) {
        return DecodeError::too_large;
      }

      if (input.size() < header_bytes) {
        return DecodeError::truncated;
      }

      if (!std::equal(magic.begin(), magic.end(), input.begin())) {
        return DecodeError::magic;
      }

      Reader reader{input.subspan(magic.size())};
      if (reader.u16() != version) {
        return DecodeError::version;
      }

      if (reader.u16() != 0) {
        return DecodeError::malformed;
      }

      counts.blocks = reader.u32();
      counts.cells = reader.u32();
      counts.runs = reader.u32();
      counts.text = reader.u32();
      // Each count is below 2^32 and each record below 2^6 bytes, so the sum cannot wrap.
      const auto expected = encodedSize(counts.blocks, counts.cells, counts.runs, counts.text);
      if (expected < input.size()) {
        return DecodeError::malformed;
      }

      if (expected > input.size()) {
        return DecodeError::truncated;
      }

      if (inspectUtf8(text(input, counts)) != Utf8Validation::valid) {
        return DecodeError::utf8;
      }

      return DecodeError::none;
    }

    DecodeError decodeBlocks(std::span<const std::uint8_t> input, std::span<Block> blocks) noexcept {
      Reader records{input.subspan(header_bytes)};

      for (auto& block : blocks) {
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
          return DecodeError::malformed;
        }

        block.kind = static_cast<BlockKind>(kind);
        block.marker = static_cast<Marker>(marker);
        block.callout = static_cast<Callout>(callout);
      }

      return DecodeError::none;
    }

    DecodeError decodeCells(std::span<const std::uint8_t> input, const Counts& counts, std::span<Cell> cells) noexcept {
      Reader records{input.subspan(header_bytes + std::size_t{counts.blocks} * block_bytes)};

      for (auto& cell : cells) {
        cell.first = records.u32();
        cell.count = records.u32();
        const auto align = records.u8();
        const auto reserved = records.u8();
        if (align >= static_cast<std::uint8_t>(Align::count) || reserved != 0 || records.u16() != 0) {
          return DecodeError::malformed;
        }

        cell.align = static_cast<Align>(align);
        if (!within(cell.first, cell.count, counts.runs)) {
          return DecodeError::range;
        }
      }

      return DecodeError::none;
    }

    DecodeError decodeRuns(std::span<const std::uint8_t> input, const Counts& counts, std::span<Run> runs) noexcept {
      const auto content = text(input, counts);
      Reader records{input.subspan(header_bytes + std::size_t{counts.blocks} * block_bytes + std::size_t{counts.cells} * cell_bytes)};

      for (auto& run : runs) {
        run.text.offset = records.u32();
        run.text.size = records.u32();
        run.target.offset = records.u32();
        run.target.size = records.u32();
        run.style = records.u16();
        if (records.u16() != 0 || (run.style & ~style::all) != 0) {
          return DecodeError::malformed;
        }

        if (!validSpan(content, run.text) || !validSpan(content, run.target)) {
          return DecodeError::range;
        }
      }

      return DecodeError::none;
    }

    DecodeError checkBlocks(std::span<const std::uint8_t> input, const Counts& counts, std::span<const Block> blocks) noexcept {
      const auto content = text(input, counts);

      for (const auto& block : blocks) {
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
          return DecodeError::malformed;
        }

        const bool in_range = [&] {
          switch (block.kind) {
          case BlockKind::paragraph:
          case BlockKind::heading:
            return within(block.first, block.count, counts.runs);
          case BlockKind::table:
            return within(block.first, block.count, counts.cells);
          case BlockKind::code:
          case BlockKind::html:
            return validSpan(content, Span{block.first, block.count});
          default:
            return true;
          }
        }();
        if (!in_range || !validSpan(content, block.info)) {
          return DecodeError::range;
        }
      }

      return DecodeError::none;
    }

    std::string_view text(std::span<const std::uint8_t> input, const Counts& counts) noexcept {
      const auto bytes = input.last(counts.text);

      return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
    }
  }

  template <Allocator Memory>
  Document<Memory>::Document(Memory& memory)
      : blocks(memory),
        cells(memory),
        runs(memory),
        text(memory) {}

  template <Allocator Memory>
  std::string_view Document<Memory>::view(Span span) const noexcept {
    return std::string_view{text}.substr(span.offset, span.size);
  }

  template <Allocator Memory>
  std::span<const Run> Document<Memory>::runsOf(const Block& block) const noexcept {
    return std::span<const Run>{runs}.subspan(block.first, block.count);
  }

  template <Allocator Memory>
  std::span<const Run> Document<Memory>::runsOf(const Cell& cell) const noexcept {
    return std::span<const Run>{runs}.subspan(cell.first, cell.count);
  }

  template <Allocator Memory>
  std::span<const Cell> Document<Memory>::cellsOf(const Block& block) const noexcept {
    return std::span<const Cell>{cells}.subspan(block.first, block.count);
  }

  template <Allocator Memory>
  void Document<Memory>::clear() noexcept {
    blocks.clear();
    cells.clear();
    runs.clear();
    text.clear();
  }

  template struct Document<Memory>;

  template <Allocator Memory>
  ds::Option<std::size_t> encodedSize(const Document<Memory>& document) noexcept {
    const auto size = detail::encodedSize(document.blocks.size(), document.cells.size(), document.runs.size(), document.text.size());

    return size <= max_document_bytes ? ds::Option<std::size_t>{static_cast<std::size_t>(size)} : ds::none;
  }

  template <Allocator Memory>
  void encode(const Document<Memory>& document, std::span<std::uint8_t> output) noexcept {
    detail::encode(document.blocks, document.cells, document.runs, document.text, output);
  }

  template <Allocator Memory>
  DecodeError decode(std::span<const std::uint8_t> input, Document<Memory>& document) {
    document.clear();
    detail::Counts counts;

    auto error = detail::decodeHeader(input, counts);
    if (error != DecodeError::none) {
      return error;
    }

    document.blocks.resize(counts.blocks);
    error = detail::decodeBlocks(input, document.blocks.viewMut());
    if (error == DecodeError::none) {
      document.cells.resize(counts.cells);
      error = detail::decodeCells(input, counts, document.cells.viewMut());
    }

    if (error == DecodeError::none) {
      document.runs.resize(counts.runs);
      error = detail::decodeRuns(input, counts, document.runs.viewMut());
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

  template ds::Option<std::size_t> encodedSize<Memory>(const Document<Memory>& document) noexcept;
  template void encode<Memory>(const Document<Memory>& document, std::span<std::uint8_t> output) noexcept;
  template DecodeError decode<Memory>(std::span<const std::uint8_t> input, Document<Memory>& document);

  bool appendSequence(const Document<Memory>& document, ds::String<Memory>& output) {
    const auto size = encodedSize(document);
    if (!size) {
      return false;
    }

    ds::Vec<std::uint8_t, Memory> bytes{output.memory()};

    bytes.resize(*size);
    encode(document, bytes.viewMut());
    const auto encoded = (*size + 2) / 3 * 4;

    output.append("\x1b]");
    output.append(sequence_begin);
    const auto body = output.size();

    output.resize(body + encoded);
    static_cast<void>(runtime::base64::encode(bytes, std::span<char>{output.dataMut() + body, encoded}));
    output.append("\x1b\\");
    return true;
  }

  void appendEnd(ds::String<Memory>& output) {
    output.append("\x1b]");
    output.append(sequence_end);
    output.append("\x1b\\");
  }

}
