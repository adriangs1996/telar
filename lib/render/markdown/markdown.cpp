module;
// entity.h declares no C linkage of its own.
extern "C" {
#include "entity.h"
}
#include "md4c.h"

module telar.render.markdown;

import std;
import telar.base.text.utf8;
import telar.base.ds;
import telar.tbc;

namespace telar::render::markdown {

  inline constexpr unsigned dialect = MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS;
  inline constexpr char32_t replacement = U'�';

  template <typename Text>
  static void appendUtf8(Text& text, char32_t value) {
    if (value == 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
      value = replacement;
    }

    if (value < 0x80) {
      text.push(static_cast<char>(value));
    } else if (value < 0x800) {
      text.push(static_cast<char>(0xc0 | (value >> 6)));
      text.push(static_cast<char>(0x80 | (value & 0x3f)));
    } else if (value < 0x10000) {
      text.push(static_cast<char>(0xe0 | (value >> 12)));
      text.push(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
      text.push(static_cast<char>(0x80 | (value & 0x3f)));
    } else {
      text.push(static_cast<char>(0xf0 | (value >> 18)));
      text.push(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
      text.push(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
      text.push(static_cast<char>(0x80 | (value & 0x3f)));
    }
  }

  // Appends an entity as md4c reports it (`&amp;`, `&#38;`, `&#x26;`), decoded.
  template <typename Text>
  static void appendEntity(Text& text, std::string_view entity) {
    if (entity.size() > 3 && entity[1] == '#') {
      const bool hex = entity[2] == 'x' || entity[2] == 'X';
      const auto digits = entity.substr(hex ? 3 : 2, entity.size() - (hex ? 4 : 3));
      std::uint32_t value = 0;
      const auto parsed = std::from_chars(digits.data(), digits.data() + digits.size(), value, hex ? 16 : 10);

      appendUtf8(text, parsed.ec == std::errc{} && parsed.ptr == digits.data() + digits.size() ? static_cast<char32_t>(value) : replacement);
      return;
    }

    if (const auto* known = entity_lookup(entity.data(), entity.size())) {
      appendUtf8(text, static_cast<char32_t>(known->codepoints[0]));
      if (known->codepoints[1] != 0) {
        appendUtf8(text, static_cast<char32_t>(known->codepoints[1]));
      }

      return;
    }

    text.append(entity);
  }

  // A copy of source with every invalid UTF-8 sequence replaced by U+FFFD, so
  // that every span of the document starts and ends on a character.
  static tbc::val_a<ds::String<Memory>> repairUtf8(std::string_view source, tbc::mut_a<Memory> memory) {
    ds::String<Memory> repaired{memory};

    repaired.reserve(source.size());
    std::size_t index = 0;

    while (index < source.size()) {
      std::size_t length = 1;

      while (length <= 4 && index + length <= source.size() && inspectUtf8(source.substr(index, length)) != Utf8Validation::valid) {
        ++length;
      }

      if (length > 4 || index + length > source.size()) {
        appendUtf8(repaired, replacement);
        ++index;
      } else {
        repaired.append(source.substr(index, length));
        index += length;
      }
    }

    return repaired;
  }

  class Builder {
  public:
    explicit Builder(Document<Memory>& document, Memory& memory)
        : document_(document),
          lists_(memory),
          callouts_(memory),
          spans_(memory) {}

    [[nodiscard]] bool overflowed() const noexcept {
      return overflow_;
    }

    [[nodiscard]] bool failed() const noexcept {
      return failed_;
    }

    static int onEnterBlock(MD_BLOCKTYPE type, void* detail, void* self) noexcept {
      return guarded(self, [&](Builder& builder) {
        return builder.enter(type, detail);
      });
    }

    static int onLeaveBlock(MD_BLOCKTYPE type, void* detail, void* self) noexcept {
      return guarded(self, [&](Builder& builder) {
        return builder.leave(type, detail);
      });
    }

    static int onEnterSpan(MD_SPANTYPE type, void* detail, void* self) noexcept {
      return guarded(self, [&](Builder& builder) {
        return builder.enterSpan(type, detail);
      });
    }

    static int onLeaveSpan(MD_SPANTYPE type, void*, void* self) noexcept {
      return guarded(self, [&](Builder& builder) {
        return builder.leaveSpan(type);
      });
    }

    static int onText(MD_TEXTTYPE type, const MD_CHAR* text, MD_SIZE size, void* self) noexcept {
      return guarded(self, [&](Builder& builder) {
        return builder.text(type, std::string_view{text, size});
      });
    }

  private:
    struct List {
      bool ordered = false;
      bool tight = false;
      std::uint32_t next = 1;
    };

    struct Frame {
      std::uint16_t style = 0;
      Span target;
      std::uint32_t runs = 0; // runs when an image began, to label an empty one
    };

    enum class Leaf : std::uint8_t {
      none,
      runs,
      verbatim,
      table,
    };

    static constexpr int abort = 1;

    // Exceptions never cross md4c's C frames: a failed allocation aborts the parse.
    template <typename Callback>
    static int guarded(void* self, Callback&& callback) noexcept {
      auto& builder = *static_cast<Builder*>(self);

      try {
        return callback(builder);
      } catch (...) {
        builder.failed_ = true;
        return abort;
      }
    }

    int enter(MD_BLOCKTYPE type, void* detail) {
      if (type != MD_BLOCK_TH && type != MD_BLOCK_TD && type != MD_BLOCK_TR && type != MD_BLOCK_THEAD && type != MD_BLOCK_TBODY) {
        closeImplicit();
      }

      switch (type) {
      case MD_BLOCK_QUOTE:
        ++quote_;
        break;
      case MD_BLOCK_ADMONITION:
        ++quote_;
        callouts_.push(callout_);
        callout_ = calloutOf(static_cast<const MD_BLOCK_ADMONITION_DETAIL*>(detail)->type);
        opens_callout_ = true;
        break;
      case MD_BLOCK_UL:
        lists_.push(List{.ordered = false, .tight = static_cast<const MD_BLOCK_UL_DETAIL*>(detail)->is_tight != 0});
        break;
      case MD_BLOCK_OL: {
        const auto* ordered = static_cast<const MD_BLOCK_OL_DETAIL*>(detail);

        lists_.push(List{.ordered = true, .tight = ordered->is_tight != 0, .next = ordered->start});
        break;
      }
      case MD_BLOCK_LI: {
        ++items_;
        const auto* item = static_cast<const MD_BLOCK_LI_DETAIL*>(detail);
        auto& list = lists_.backMut();

        marker_ = (item->is_task != 0) ? (item->task_mark == ' ' ? Marker::task_open : Marker::task_done) : list.ordered ? Marker::ordered
                                                                                                                         : Marker::bullet;
        number_ = list.ordered ? list.next++ : 0;
        break;
      }
      case MD_BLOCK_FOOTNOTE_DEF_SECTION:
        open(BlockKind::rule);
        close();
        break;
      case MD_BLOCK_FOOTNOTE_DEF:
        ++items_;
        marker_ = Marker::footnote;
        number_ = static_cast<const MD_BLOCK_FOOTNOTE_DEF_DETAIL*>(detail)->id;
        break;
      case MD_BLOCK_HR:
        open(BlockKind::rule);
        break;
      case MD_BLOCK_H:
        open(BlockKind::heading, static_cast<std::uint8_t>(static_cast<const MD_BLOCK_H_DETAIL*>(detail)->level));
        break;
      case MD_BLOCK_P:
        open(BlockKind::paragraph);
        break;
      case MD_BLOCK_CODE: {
        const auto info = attribute(static_cast<const MD_BLOCK_CODE_DETAIL*>(detail)->lang);

        open(BlockKind::code);
        document_.blocks.atMut(document_.blocks.size() - 1).info = info;
        break;
      }
      case MD_BLOCK_HTML:
        open(BlockKind::html);
        break;
      case MD_BLOCK_TABLE: {
        const auto columns = static_cast<const MD_BLOCK_TABLE_DETAIL*>(detail)->col_count;

        open(BlockKind::table);
        document_.blocks.atMut(document_.blocks.size() - 1).columns = static_cast<std::uint16_t>(std::min<unsigned>(columns, std::numeric_limits<std::uint16_t>::max()));
        break;
      }
      case MD_BLOCK_TH:
      case MD_BLOCK_TD:
        floor_ = static_cast<std::uint32_t>(document_.runs.size());
        document_.cells.push(Cell{.first = floor_, .count = 0, .align = alignOf(static_cast<const MD_BLOCK_TD_DETAIL*>(detail)->align)});
        break;
      default:
        break;
      }

      return overflow_ ? abort : 0;
    }

    int leave(MD_BLOCKTYPE type, void*) {
      switch (type) {
      case MD_BLOCK_QUOTE:
        closeImplicit();
        --quote_;
        break;
      case MD_BLOCK_ADMONITION:
        closeImplicit();
        --quote_;
        callout_ = callouts_.back();
        callouts_.truncate(callouts_.size() - 1);
        opens_callout_ = false;
        break;
      case MD_BLOCK_UL:
      case MD_BLOCK_OL:
        lists_.truncate(lists_.size() - 1);
        break;
      case MD_BLOCK_LI:
      case MD_BLOCK_FOOTNOTE_DEF:
        closeImplicit();
        // An empty item still shows its marker.
        if (marker_ != Marker::none) {
          open(BlockKind::paragraph);
          close();
        }

        --items_;
        break;
      case MD_BLOCK_H:
      case MD_BLOCK_P:
      case MD_BLOCK_CODE:
      case MD_BLOCK_HTML:
      case MD_BLOCK_HR:
      case MD_BLOCK_TABLE:
        close();
        break;
      case MD_BLOCK_TH:
      case MD_BLOCK_TD: {
        auto& cell = document_.cells.backMut();

        cell.count = static_cast<std::uint32_t>(document_.runs.size()) - cell.first;
        break;
      }
      default:
        break;
      }

      return overflow_ ? abort : 0;
    }

    int enterSpan(MD_SPANTYPE type, void* detail) {
      Frame frame{.style = style_, .target = target_, .runs = static_cast<std::uint32_t>(document_.runs.size())};

      switch (type) {
      case MD_SPAN_EM:
        style_ |= style::emphasis;
        break;
      case MD_SPAN_STRONG:
        style_ |= style::strong;
        break;
      case MD_SPAN_CODE:
        style_ |= style::code;
        break;
      case MD_SPAN_DEL:
        style_ |= style::strike;
        break;
      case MD_SPAN_LATEXMATH:
      case MD_SPAN_LATEXMATH_DISPLAY:
        style_ |= style::math;
        break;
      case MD_SPAN_A:
        style_ |= style::link;
        target_ = attribute(static_cast<const MD_SPAN_A_DETAIL*>(detail)->href);
        break;
      case MD_SPAN_IMG:
        style_ |= style::image;
        target_ = attribute(static_cast<const MD_SPAN_IMG_DETAIL*>(detail)->src);
        break;
      case MD_SPAN_FOOTNOTE_REF: {
        ds::Array<char, 16> digits;
        auto* const end = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), static_cast<const MD_SPAN_FOOTNOTE_REF_DETAIL*>(detail)->id).ptr;

        appendRun(std::string_view{digits.data(), static_cast<std::size_t>(end - digits.data())}, style::superscript);
        break;
      }
      default:
        break;
      }

      spans_.push(frame);
      return overflow_ ? abort : 0;
    }

    int leaveSpan(MD_SPANTYPE type) {
      const auto frame = spans_.back();
      if (type == MD_SPAN_IMG && document_.runs.size() == frame.runs) {
        appendRun("image", 0);
      }

      spans_.truncate(spans_.size() - 1);
      style_ = frame.style;
      target_ = frame.target;
      return overflow_ ? abort : 0;
    }

    int text(MD_TEXTTYPE type, std::string_view value) {
      if (leaf_ == Leaf::verbatim) {
        appendVerbatim(value);
        return overflow_ ? abort : 0;
      }

      switch (type) {
      case MD_TEXT_NULLCHAR: {
        ds::String<Memory> character{document_.text.memory()};

        appendUtf8(character, replacement);
        appendRun(character, 0);
        break;
      }
      case MD_TEXT_BR:
        appendRun("\n", 0);
        break;
      case MD_TEXT_SOFTBR:
        appendRun(" ", 0);
        break;
      case MD_TEXT_ENTITY: {
        ds::String<Memory> decoded{document_.text.memory()};

        appendEntity(decoded, value);
        appendRun(decoded, 0);
        break;
      }
      case MD_TEXT_HTML:
        appendRun(value, style::html);
        break;
      default:
        appendRun(value, 0);
        break;
      }

      return overflow_ ? abort : 0;
    }

    void open(BlockKind kind, std::uint8_t level = 0) {
      const bool in_list = items_ != 0 && !lists_.empty();
      Block block{
          .kind = kind,
          .level = level,
          .quote = static_cast<std::uint8_t>(std::min<std::uint32_t>(quote_, max_nesting)),
          .list = static_cast<std::uint8_t>(std::min<std::uint32_t>(items_, max_nesting)),
          .marker = marker_,
          .callout = callout_,
          .flags = static_cast<std::uint8_t>((in_list && lists_.back().tight ? Block::tight : 0) | (opens_callout_ ? Block::opens_callout : 0)),
          .number = number_,
          .info = {},
      };

      marker_ = Marker::none;
      number_ = 0;
      opens_callout_ = false;
      switch (kind) {
      case BlockKind::paragraph:
      case BlockKind::heading:
        leaf_ = Leaf::runs;
        block.first = static_cast<std::uint32_t>(document_.runs.size());
        floor_ = block.first;
        break;
      case BlockKind::code:
      case BlockKind::html:
        leaf_ = Leaf::verbatim;
        block.first = static_cast<std::uint32_t>(document_.text.size());
        break;
      case BlockKind::table:
        leaf_ = Leaf::table;
        block.first = static_cast<std::uint32_t>(document_.cells.size());
        break;
      case BlockKind::rule:
      case BlockKind::count:
        leaf_ = Leaf::none;
        break;
      }

      document_.blocks.push(block);
    }

    void close() {
      if (document_.blocks.empty()) {
        return;
      }

      auto& block = document_.blocks.backMut();

      switch (leaf_) {
      case Leaf::runs:
        block.count = static_cast<std::uint32_t>(document_.runs.size()) - block.first;
        break;
      case Leaf::verbatim: {
        // Code ends with its last line's '\n'; the block itself separates lines.
        auto end = document_.text.size();

        while (end > block.first && document_.text[end - 1] == '\n') {
          --end;
        }

        block.count = static_cast<std::uint32_t>(end - block.first);
        break;
      }
      case Leaf::table:
        block.count = static_cast<std::uint32_t>(document_.cells.size()) - block.first;
        break;
      case Leaf::none:
        break;
      }

      leaf_ = Leaf::none;
      implicit_ = false;
    }

    // Tight list items hold their text without a paragraph; it gets one here.
    void ensureLeaf() {
      if (leaf_ == Leaf::none && !inCell()) {
        open(BlockKind::paragraph);
        implicit_ = true;
      }
    }

    void closeImplicit() {
      if (implicit_) {
        close();
      }
    }

    [[nodiscard]] bool inCell() const noexcept {
      return leaf_ == Leaf::table;
    }

    [[nodiscard]] bool reserve(std::size_t bytes) {
      if (document_.text.size() + bytes > max_document_bytes || document_.runs.size() >= max_document_bytes / run_bytes) {
        overflow_ = true;
      }

      return !overflow_;
    }

    void appendRun(std::string_view value, std::uint16_t extra) {
      if (value.empty()) {
        return;
      }

      ensureLeaf();
      if (!reserve(value.size())) {
        return;
      }

      const auto offset = static_cast<std::uint32_t>(document_.text.size());

      document_.text.append(value);
      const auto style = static_cast<std::uint16_t>(style_ | extra);
      auto& runs = document_.runs;
      if (runs.size() > floor_ && runs.back().style == style && runs.back().target == target_ && runs.back().text.offset + runs.back().text.size == offset) {
        runs.atMut(runs.size() - 1).text.size += static_cast<std::uint32_t>(value.size());
        return;
      }

      runs.push(Run{.text = Span{.offset = offset, .size = static_cast<std::uint32_t>(value.size())}, .target = target_, .style = style});
    }

    void appendVerbatim(std::string_view value) {
      if (reserve(value.size())) {
        document_.text.append(value);
      }
    }

    // Writes an attribute's text, entities decoded, and returns where it is.
    Span attribute(const MD_ATTRIBUTE& value) {
      const auto offset = static_cast<std::uint32_t>(document_.text.size());

      if (!reserve(value.size * 4)) {
        return {};
      }

      for (std::size_t index = 0; value.substr_offsets[index] < value.size; ++index) {
        const auto begin = value.substr_offsets[index];
        const std::string_view part{value.text + begin, value.substr_offsets[index + 1] - begin};

        switch (value.substr_types[index]) {
        case MD_TEXT_ENTITY:
          appendEntity(document_.text, part);
          break;
        case MD_TEXT_NULLCHAR:
          appendUtf8(document_.text, replacement);
          break;
        default:
          document_.text.append(part);
          break;
        }
      }

      return Span{.offset = offset, .size = static_cast<std::uint32_t>(document_.text.size() - offset)};
    }

    static Callout calloutOf(const MD_ATTRIBUTE& type) {
      constexpr ds::Array<std::pair<std::string_view, Callout>, 5> names{{
          {"note", Callout::note},
          {"tip", Callout::tip},
          {"important", Callout::important},
          {"warning", Callout::warning},
          {"caution", Callout::caution},
      }};

      const std::string_view name{type.text, type.size};

      for (const auto& [text, callout] : names) {
        if (text == name) {
          return callout;
        }
      }

      return Callout::note;
    }

    static Align alignOf(MD_ALIGN align) noexcept {
      switch (align) {
      case MD_ALIGN_LEFT:
        return Align::left;
      case MD_ALIGN_CENTER:
        return Align::center;
      case MD_ALIGN_RIGHT:
        return Align::right;
      default:
        return Align::start;
      }
    }

    Document<Memory>& document_;
    ds::Vec<List, Memory> lists_;
    ds::Vec<Callout, Memory> callouts_;
    ds::Vec<Frame, Memory> spans_;
    std::uint32_t quote_ = 0;
    std::uint32_t items_ = 0;
    Marker marker_ = Marker::none;
    std::uint32_t number_ = 0;
    Callout callout_ = Callout::none;
    bool opens_callout_ = false;
    Leaf leaf_ = Leaf::none;
    bool implicit_ = false;
    std::uint32_t floor_ = 0; // runs below this belong to an earlier block or cell
    std::uint16_t style_ = 0;
    Span target_;
    bool overflow_ = false;
    bool failed_ = false;
  };

  Error render(std::string_view source, Document<Memory>& document) {
    document.clear();
    if (source.size() > max_source_bytes) {
      return Error::too_large;
    }

    Memory& memory = document.text.memory();
    ds::String<Memory> repaired{memory};

    if (inspectUtf8(source) != Utf8Validation::valid) {
      repaired = repairUtf8(source, memory);
      source = repaired;
    }

    Builder builder{document, memory};
    const MD_PARSER parser{
        .abi_version = 0,
        .flags = dialect,
        .enter_block = &Builder::onEnterBlock,
        .leave_block = &Builder::onLeaveBlock,
        .enter_span = &Builder::onEnterSpan,
        .leave_span = &Builder::onLeaveSpan,
        .text = &Builder::onText,
        .debug_log = nullptr,
        .syntax = nullptr,
    };

    const auto result = md_parse(source.data(), static_cast<MD_SIZE>(source.size()), &parser, &builder);

    if (builder.overflowed() && !builder.failed()) {
      document.clear();
      return Error::document_too_large;
    }

    if (result != 0) {
      document.clear();
      return Error::parser;
    }

    if (!encodedSize(document)) {
      document.clear();
      return Error::document_too_large;
    }

    return Error::none;
  }

}
