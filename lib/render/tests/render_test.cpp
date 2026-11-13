import std;
import telar.base.memory;
import telar.base.text;
import telar.render.document;
import telar.render.markdown;
import telar.render.terminal;

namespace {

  using namespace telar;
  using namespace telar::render;
  using Memory = SystemAllocator;
  using Doc = Document<Memory>;

  int failures = 0;

  void check(bool condition, std::string_view what, std::source_location where = std::source_location::current()) {
    if (!condition) {
      ++failures;
      std::println(std::cerr, "FAIL line {}: {}", where.line(), what);
    }
  }

  Memory memory;

  Doc parse(std::string_view source) {
    Doc document{memory};
    const auto error = markdown::render(source, document);

    check(error == markdown::Error::none, "markdown renders");
    return document;
  }

  std::string text(const Doc &document, std::span<const Run> runs) {
    std::string joined;

    for (const auto &run : runs) {
      joined += document.view(run.text);
    }

    return joined;
  }

  const Block *find(const Doc &document, BlockKind kind, std::size_t nth = 0) {
    for (const auto &block : document.blocks) {
      if (block.kind == kind && nth-- == 0) {
        return &block;
      }
    }

    return nullptr;
  }

  std::vector<std::uint8_t> encoded(const Doc &document) {
    std::vector<std::uint8_t> bytes(*encodedSize(document));

    encode(document, bytes);
    return bytes;
  }

  constexpr std::string_view sample = R"(# Title &amp; more

Some *emphasis*, **strong**, `code`, ~~gone~~ and a [link](https://example.com "t").
Second line.\
Hard break.

- one
- two
  - nested
- [x] done
- [ ] open

3. three
4. four

> quoted
>
> > deeper

> [!WARNING]
> Careful.

```zig
const x = 1;
```

| Left | Center | Right |
| :--- | :----: | ----: |
| a | **b** | c |
| d |

![alt text](image.png)

Footnote[^1].

[^1]: The note.

---

<div>raw</div>
)";

  void structure() {
    const auto document = parse(sample);

    const auto *title = find(document, BlockKind::heading);

    check(title != nullptr && title->level == 1, "heading level");
    check(title && text(document, document.runsOf(*title)) == "Title & more", "entity decoded in heading");

    const auto *paragraph = find(document, BlockKind::paragraph);

    check(paragraph != nullptr, "paragraph");
    if (paragraph) {
      const auto runs = document.runsOf(*paragraph);

      check(text(document, runs) == "Some emphasis, strong, code, gone and a link. Second line.\nHard break.", std::format("paragraph text {:?}", text(document, runs)));
      const auto styled = [&](std::uint16_t style) {
        return std::ranges::any_of(runs, [&](const Run &run) { return (run.style & style) != 0; });
      };

      check(styled(style::emphasis) && styled(style::strong) && styled(style::code) && styled(style::strike), "inline styles");
      const auto link = std::ranges::find_if(runs, [](const Run &run) { return (run.style & style::link) != 0; });

      check(link != runs.end() && document.view(link->text) == "link" && document.view(link->target) == "https://example.com", "link target");
    }

    // Tight list items get implicit paragraphs with markers.
    const auto *one = find(document, BlockKind::paragraph, 1);

    check(one && one->marker == Marker::bullet && one->list == 1 && (one->flags & Block::tight) != 0, "bullet item");
    const auto *nested = find(document, BlockKind::paragraph, 3);

    check(nested && nested->list == 2 && text(document, document.runsOf(*nested)) == "nested", "nested item");
    const auto *done = find(document, BlockKind::paragraph, 4);

    check(done && done->marker == Marker::task_done, "done task");
    const auto *open = find(document, BlockKind::paragraph, 5);

    check(open && open->marker == Marker::task_open, "open task");
    const auto *three = find(document, BlockKind::paragraph, 6);

    check(three && three->marker == Marker::ordered && three->number == 3, "ordered start");
    const auto *four = find(document, BlockKind::paragraph, 7);

    check(four && four->number == 4, "ordered next");

    const auto *quoted = find(document, BlockKind::paragraph, 8);

    check(quoted && quoted->quote == 1 && quoted->list == 0, "quote depth");
    const auto *deeper = find(document, BlockKind::paragraph, 9);

    check(deeper && deeper->quote == 2, "nested quote");
    const auto *careful = find(document, BlockKind::paragraph, 10);

    check(careful && careful->callout == Callout::warning && (careful->flags & Block::opens_callout) != 0 && careful->quote == 1, "callout");

    const auto *code = find(document, BlockKind::code);

    check(code && document.view(code->info) == "zig" && document.view(Span{code->first, code->count}) == "const x = 1;", "code block");

    const auto *table = find(document, BlockKind::table);

    check(table && table->columns == 3 && table->count == 9, "table shape pads short rows");
    if (table) {
      const auto cells = document.cellsOf(*table);

      check(cells[0].align == Align::left && cells[1].align == Align::center && cells[2].align == Align::right, "alignment");
      check(text(document, document.runsOf(cells[4])) == "b" && (document.runsOf(cells[4])[0].style & style::strong) != 0, "styled cell");
      check(cells[8].count == 0, "padded cell is empty");
    }

    const auto *image = find(document, BlockKind::paragraph, 11);

    check(image && document.runsOf(*image).size() == 1 && (document.runsOf(*image)[0].style & style::image) != 0 && document.view(document.runsOf(*image)[0].target) == "image.png", "image keeps alt text and source");

    const auto *footnote_ref = find(document, BlockKind::paragraph, 12);

    check(footnote_ref && text(document, document.runsOf(*footnote_ref)) == "Footnote1.", "footnote reference");
    const auto *html = find(document, BlockKind::html);

    check(html && document.view(Span{html->first, html->count}) == "<div>raw</div>", "html block");
    const auto *note = find(document, BlockKind::paragraph, 13);

    check(note && note->marker == Marker::footnote && note->number == 1, "footnote definition");
    check(find(document, BlockKind::rule, 1) != nullptr, "rules: footnote section and thematic break");
  }

  void roundTrip() {
    const auto document = parse(sample);
    const auto bytes = encoded(document);
    Doc decoded{memory};

    check(decode(bytes, decoded) == DecodeError::none, "decode accepts encoded document");
    check(std::ranges::equal(decoded.blocks, document.blocks) && std::ranges::equal(decoded.cells, document.cells) && std::ranges::equal(decoded.runs, document.runs) && decoded.text == document.text, "round trip");

    Doc empty{memory};
    Doc empty_decoded{memory};

    check(decode(encoded(empty), empty_decoded) == DecodeError::none && empty_decoded.blocks.empty(), "empty document");
  }

  void rejection() {
    const auto document = parse(sample);
    const auto bytes = encoded(document);
    Doc decoded{memory};

    check(decode(std::span{bytes}.first(10), decoded) == DecodeError::truncated, "short header");
    check(decode(std::span{bytes}.first(bytes.size() - 1), decoded) == DecodeError::truncated, "truncated text");
    auto longer = bytes;

    longer.push_back(0);
    check(decode(longer, decoded) == DecodeError::malformed, "trailing bytes");

    auto magic = bytes;

    magic[0] = 'X';
    check(decode(magic, decoded) == DecodeError::magic, "magic");

    auto version = bytes;

    version[4] = 2;
    check(decode(version, decoded) == DecodeError::version, "version");

    auto kind = bytes;

    kind[header_bytes] = static_cast<std::uint8_t>(BlockKind::count);
    check(decode(kind, decoded) == DecodeError::malformed && decoded.blocks.empty(), "unknown block kind leaves the document empty");

    auto reserved = bytes;

    reserved[header_bytes + 7] = 1;
    check(decode(reserved, decoded) == DecodeError::malformed, "reserved byte");

    // The first block's run range, pushed past the runs.
    auto range = bytes;
    const auto count_at = header_bytes + 20;

    range[count_at + 3] = 0x7f;
    check(decode(range, decoded) == DecodeError::range, "run range");

    auto utf8 = bytes;

    utf8.back() = 0xff;
    check(decode(utf8, decoded) == DecodeError::utf8, "invalid UTF-8 text");

    // A run that starts inside a character.
    Doc split{memory};

    split.text = "\xc3\xa9";
    split.blocks.push_back(Block{.kind = BlockKind::paragraph, .first = 0, .count = 1, .info = {}});
    split.runs.push_back(Run{.text = Span{1, 1}, .target = {}, .style = 0});
    check(decode(encoded(split), decoded) == DecodeError::range, "span splits a character");

    // Mutations never crash and never yield an inconsistent document.
    std::mt19937 random{7};

    for (int round = 0; round < 20000; ++round) {
      auto mutated = bytes;
      const auto changes = 1 + random() % 4;

      for (unsigned change = 0; change < changes; ++change) {
        mutated[random() % mutated.size()] = static_cast<std::uint8_t>(random());
      }

      if (decode(mutated, decoded) == DecodeError::none) {
        for (const auto &block : decoded.blocks) {
          if (block.kind == BlockKind::paragraph || block.kind == BlockKind::heading) {
            check(block.first + block.count <= decoded.runs.size(), "accepted runs in range");
          }
        }
      }
    }
  }

  void repair() {
    Doc document{memory};

    check(markdown::render("caf\xc3 ok \xff", document) == markdown::Error::none, "invalid UTF-8 source renders");
    check(inspectUtf8(document.text) == Utf8Validation::valid, "document text is repaired");
    Doc decoded{memory};

    check(decode(encoded(document), decoded) == DecodeError::none, "repaired document decodes");
  }

  void limits() {
    std::string large(markdown::max_source_bytes + 1, 'a');
    Doc document{memory};

    check(markdown::render(large, document) == markdown::Error::too_large, "source limit");

    // Deep nesting is kept at the limit, not beyond it.
    std::string deep;

    for (int level = 0; level < 100; ++level) {
      deep += '>';
    }

    deep += " x";
    const auto nested = parse(deep);

    check(!nested.blocks.empty() && nested.blocks.back().quote == max_nesting, "nesting limit");
    Doc decoded{memory};

    check(decode(encoded(nested), decoded) == DecodeError::none, "deep document decodes");
  }

  void sequence() {
    const auto document = parse(sample);
    String<Memory> output{AllocatorRef<char, Memory>{memory}};

    check(appendSequence(document, output), "sequence fits");
    const std::string_view view{output};

    check(view.starts_with("\x1b]7780;begin;") && view.ends_with("\x1b\\"), "sequence framing");
    const auto body = view.substr(2 + sequence_begin.size(), view.size() - 4 - sequence_begin.size());
    std::vector<std::uint8_t> bytes(body.size());
    const auto size = runtime::base64::decode(body, bytes);

    check(size.has_value(), "base64 body");
    if (size) {
      bytes.resize(*size);
      Doc decoded{memory};

      check(decode(bytes, decoded) == DecodeError::none && decoded.text == document.text, "sequence carries the document");
    }

    String<Memory> end{AllocatorRef<char, Memory>{memory}};

    appendEnd(end);
    check(std::string_view{end} == "\x1b]7780;end\x1b\\", "end framing");
  }

  void terminalText() {
    const auto document = parse(std::string{sample} + "\nInjected \x1b]52;c;evil\x07 text\n");
    String<Memory> output{AllocatorRef<char, Memory>{memory}};

    terminal::render(document, 60, output);
    const std::string_view view{output};

    check(view.find("Title & more") != std::string_view::npos, "heading text");
    check(view.find("•") != std::string_view::npos && view.find("☑") != std::string_view::npos, "list markers");
    check(view.find("<https://example.com>") != std::string_view::npos, "link destination");
    check(view.find("Warning") != std::string_view::npos, "callout title");
    check(view.find("┌") != std::string_view::npos, "table border");
    // Every escape is an SGR: document text cannot reach the terminal as a control.
    for (std::size_t at = view.find('\x1b'); at != std::string_view::npos; at = view.find('\x1b', at + 1)) {
      const auto end = view.find_first_not_of("0123456789;", at + 2);

      check(view[at + 1] == '[' && end != std::string_view::npos && view[end] == 'm', "only SGR escapes");
    }

    check(view.find('\x07') == std::string_view::npos, "no BEL");

    // Lines fit the width, measured without escapes.
    std::size_t width = 0;
    bool escape = false;
    std::size_t widest = 0;

    for (std::size_t index = 0; index < view.size();) {
      const auto byte = static_cast<unsigned char>(view[index]);

      if (escape) {
        escape = byte != 'm';
        ++index;
        continue;
      }

      if (byte == 0x1b) {
        escape = true;
        ++index;
        continue;
      }

      if (byte == '\n') {
        widest = std::max(widest, width);
        width = 0;
        ++index;
        continue;
      }

      index += byte < 0x80 ? 1 : byte < 0xe0 ? 2
                             : byte < 0xf0   ? 3
                                             : 4;
      ++width;
    }

    check(widest <= 60, "wrapped to width");
  }

}

int main() {
  structure();
  roundTrip();
  rejection();
  repair();
  limits();
  sequence();
  terminalText();
  if (failures != 0) {
    std::println(std::cerr, "{} failures", failures);
    return 1;
  }

  std::println("telar-render: all tests passed");
  return 0;
}
