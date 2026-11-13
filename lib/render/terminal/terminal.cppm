export module telar.render.terminal;

import std;
export import telar.render.document;

// Draws a Document as styled terminal text wrapped to a width, for terminals
// that cannot show it natively. Only SGR sequences are written: document text
// never carries a control character to the terminal.
export namespace telar::render::terminal {

  inline constexpr std::uint16_t min_width = 20;

  template <Allocator Memory, Allocator Output>
  void render(const Document<Memory>& document, std::uint16_t width, String<Output>& output);

}

namespace telar::render::terminal {

  inline constexpr std::size_t list_indent = 3;
  inline constexpr std::string_view reset = "\x1b[0m";

  // Columns a character occupies: two for East Asian wide and emoji ranges,
  // zero for combining marks, one otherwise. An approximation of wcwidth.
  constexpr unsigned columns(char32_t value) noexcept {
    if ((value >= 0x0300 && value <= 0x036f) || (value >= 0x200b && value <= 0x200f) || (value >= 0xfe00 && value <= 0xfe0f)) {
      return 0;
    }

    const bool wide = (value >= 0x1100 && value <= 0x115f) || (value >= 0x2e80 && value <= 0xa4cf) || (value >= 0xac00 && value <= 0xd7a3) ||
                      (value >= 0xf900 && value <= 0xfaff) || (value >= 0xfe30 && value <= 0xfe4f) || (value >= 0xff00 && value <= 0xff60) ||
                      (value >= 0xffe0 && value <= 0xffe6) || (value >= 0x1f300 && value <= 0x1f64f) || (value >= 0x1f900 && value <= 0x1f9ff) ||
                      (value >= 0x20000 && value <= 0x3fffd);

    return wide ? 2 : 1;
  }

  // Decodes the character at index of valid UTF-8 and advances index.
  inline char32_t next(std::string_view text, std::size_t& index) noexcept {
    const auto lead = static_cast<std::uint8_t>(text[index]);
    const std::size_t length = lead < 0x80 ? 1 : lead < 0xe0 ? 2
                                             : lead < 0xf0   ? 3
                                                             : 4;
    char32_t value = length == 1 ? lead : lead & (0x7f >> length);

    for (std::size_t offset = 1; offset < length && index + offset < text.size(); ++offset) {
      value = (value << 6) | (static_cast<std::uint8_t>(text[index + offset]) & 0x3f);
    }

    index += length;
    return value;
  }

  inline std::size_t displayWidth(std::string_view text) noexcept {
    std::size_t width = 0;

    for (std::size_t index = 0; index < text.size();) {
      width += columns(next(text, index));
    }

    return width;
  }

  inline bool control(char32_t value) noexcept {
    return value < 0x20 || (value >= 0x7f && value < 0xa0);
  }

  inline std::string_view calloutColor(Callout callout) noexcept {
    switch (callout) {
    case Callout::note:
      return "\x1b[34m";
    case Callout::tip:
      return "\x1b[32m";
    case Callout::important:
      return "\x1b[35m";
    case Callout::warning:
      return "\x1b[33m";
    case Callout::caution:
      return "\x1b[31m";
    default:
      return "\x1b[2m";
    }
  }

  inline std::string_view calloutTitle(Callout callout) noexcept {
    switch (callout) {
    case Callout::note:
      return "Note";
    case Callout::tip:
      return "Tip";
    case Callout::important:
      return "Important";
    case Callout::warning:
      return "Warning";
    case Callout::caution:
      return "Caution";
    default:
      return {};
    }
  }

  template <Allocator Memory, Allocator Output>
  class Painter {
  public:
    Painter(const Document<Memory>& document, std::size_t width, String<Output>& output)
        : document_(document),
          width_(width),
          output_(output),
          destination_(output.get_allocator()) {}

    void paint() {
      const Block* previous = nullptr;

      for (const auto& block : document_.blocks) {
        if (previous != nullptr && (block.flags & Block::tight) == 0) {
          blankLine(*previous, block);
        }

        previous = &block;
        if ((block.flags & Block::opens_callout) != 0) {
          prefix(block, false);
          output_.append(calloutColor(block.callout));
          output_.append("\x1b[1m");
          output_.append(calloutTitle(block.callout));
          output_.append(reset);
          output_.push_back('\n');
        }

        switch (block.kind) {
        case BlockKind::paragraph:
          flow(block, document_.runsOf(block), 0);
          break;
        case BlockKind::heading:
          flow(block, document_.runsOf(block), block.level == 1 ? style::strong | heading_one : style::strong | heading_other);
          break;
        case BlockKind::code:
        case BlockKind::html:
          verbatim(block);
          break;
        case BlockKind::rule:
          rule(block);
          break;
        case BlockKind::table:
          table(block);
          break;
        case BlockKind::count:
          break;
        }
      }
    }

  private:
    // Private style bits beyond the document's, for headings.
    static constexpr std::uint32_t heading_one = 1u << 16;
    static constexpr std::uint32_t heading_other = 1u << 17;

    // Writes the quote bars and list indentation of a line; the marker only on
    // the first line of a block that carries one. Returns the columns used.
    std::size_t prefix(const Block& block, bool marker) {
      std::size_t used = 0;

      for (std::uint8_t level = 0; level < block.quote; ++level) {
        output_.append(level + 1 == block.quote ? calloutColor(block.callout) : std::string_view{"\x1b[2m"});
        output_.append("│ ");
        output_.append(reset);
        used += 2;
      }

      if (block.list == 0) {
        return used;
      }

      const auto indent = (block.list - 1) * list_indent;

      output_.append(indent, ' ');
      used += indent;
      if (!marker || block.marker == Marker::none) {
        output_.append(list_indent, ' ');
        return used + list_indent;
      }

      std::array<char, 24> text{};
      std::size_t length = 0;
      std::size_t shown = 0;
      const auto put = [&](std::string_view value, std::size_t width) {
        std::copy(value.begin(), value.end(), text.data() + length);
        length += value.size();
        shown += width;
      };

      switch (block.marker) {
      case Marker::bullet:
        put("•", 1);
        break;
      case Marker::task_open:
        put("☐", 1);
        break;
      case Marker::task_done:
        put("☑", 1);
        break;
      case Marker::ordered:
      case Marker::footnote: {
        const auto end = std::to_chars(text.data() + length, text.data() + text.size() - 2, block.number).ptr;

        shown += static_cast<std::size_t>(end - (text.data() + length));
        length = static_cast<std::size_t>(end - text.data());
        put(block.marker == Marker::ordered ? "." : ":", 1);
        break;
      }
      default:
        break;
      }

      output_.append("\x1b[2m");
      output_.append(text.data(), length);
      output_.append(reset);
      const auto pad = shown + 1 > list_indent ? 1 : list_indent - shown;

      output_.append(pad, ' ');
      return used + shown + pad;
    }

    void blankLine(const Block& previous, const Block& block) {
      // Keep the quote bars both blocks share across the gap between them.
      Block bars{};

      bars.quote = std::min(previous.quote, block.quote);
      bars.callout = (block.flags & Block::opens_callout) != 0 ? previous.callout : block.callout;
      prefix(bars, false);
      trimTrailingSpace();
      output_.push_back('\n');
    }

    void trimTrailingSpace() {
      while (!output_.empty() && output_.back() == ' ') {
        output_.pop_back();
      }
    }

    std::size_t available(std::size_t used) const noexcept {
      return width_ > used + 1 ? width_ - used : 1;
    }

    // Moves the terminal from style current to style; 0 is the reset state
    // every line starts and ends in.
    void setStyle(std::uint32_t& current, std::uint32_t style) {
      if (style == current) {
        return;
      }

      if (current != 0) {
        output_.append(reset);
      }

      current = style;
      if ((style & heading_one) != 0) {
        output_.append("\x1b[35m");
      } else if ((style & heading_other) != 0) {
        output_.append("\x1b[34m");
      }

      if ((style & style::strong) != 0) {
        output_.append("\x1b[1m");
      }

      if ((style & style::emphasis) != 0) {
        output_.append("\x1b[3m");
      }

      if ((style & (style::code | style::math)) != 0) {
        output_.append("\x1b[36m");
      }

      if ((style & style::strike) != 0) {
        output_.append("\x1b[9m");
      }

      if ((style & style::link) != 0) {
        output_.append("\x1b[4;34m");
      }

      if ((style & (style::image | style::html | style::superscript)) != 0) {
        output_.append("\x1b[2m");
      }
    }

    // Lays out runs as words wrapped to the width, keeping the prefix on every line.
    void flow(const Block& block, std::span<const Run> runs, std::uint32_t base) {
      auto used = prefix(block, true);
      std::size_t column = 0;
      const auto limit = available(used);
      std::uint32_t current = 0;
      bool pending_space = false;

      const auto newline = [&] {
        trimTrailingSpace();
        setStyle(current, 0);
        output_.push_back('\n');
        used = prefix(block, false);
        column = 0;
        pending_space = false;
      };

      const auto word = [&](std::string_view text, std::uint32_t style) {
        const auto width = displayWidth(text);
        const auto space = pending_space && column != 0 ? 1u : 0u;
        if (column != 0 && column + space + width > limit) {
          newline();
        } else if (space != 0) {
          // A space between differently styled words takes neither style.
          if (style != current) {
            setStyle(current, 0);
          }

          output_.push_back(' ');
          ++column;
        }

        pending_space = false;
        setStyle(current, style);
        for (std::size_t index = 0; index < text.size();) {
          const auto begin = index;
          const auto value = next(text, index);
          const auto cells = columns(value);
          if (column != 0 && column + cells > limit) {
            newline();
            setStyle(current, style);
          }

          if (!control(value)) {
            output_.append(text.substr(begin, index - begin));
            column += cells;
          }
        }
      };

      const auto words = [&](std::string_view text, std::uint32_t style) {
        std::size_t start = 0;

        for (std::size_t index = 0; index <= text.size(); ++index) {
          if (index < text.size() && text[index] != ' ' && text[index] != '\n' && text[index] != '\t') {
            continue;
          }

          if (index > start) {
            word(text.substr(start, index - start), style);
          }

          if (index < text.size()) {
            if (text[index] == '\n') {
              newline();
            } else {
              pending_space = true;
            }
          }

          start = index + 1;
        }
      };

      for (std::size_t index = 0; index < runs.size(); ++index) {
        const auto& run = runs[index];
        const auto style = base | run.style;
        const auto text = document_.view(run.text);

        if ((run.style & style::image) != 0) {
          words("[", style);
        }

        words(text, style);
        if ((run.style & style::image) != 0) {
          word("]", style);
        }

        const bool ends_target = (run.style & (style::link | style::image)) != 0 && (index + 1 == runs.size() || runs[index + 1].target != run.target);
        const auto target = document_.view(run.target);
        if (ends_target && !target.empty() && target != text && target.find_first_of(" \t\n") == std::string_view::npos) {
          destination_.assign("<");
          destination_.append(target);
          destination_.push_back('>');
          pending_space = true;
          word(destination_, style::html);
        }
      }

      setStyle(current, 0);
      output_.push_back('\n');
    }

    void verbatim(const Block& block) {
      const auto text = document_.view(Span{block.first, block.count});
      const auto info = document_.view(block.info);
      if (!info.empty()) {
        prefix(block, true);
        output_.append("\x1b[2m");
        appendClean(info);
        output_.append(reset);
        output_.push_back('\n');
      }

      bool marker = info.empty();
      std::size_t start = 0;

      while (start <= text.size()) {
        auto end = text.find('\n', start);
        if (end == std::string_view::npos) {
          end = text.size();
        }

        prefix(block, marker);
        marker = false;
        output_.append(block.kind == BlockKind::html ? std::string_view{"\x1b[2m  "} : std::string_view{"\x1b[36m  "});
        appendClean(text.substr(start, end - start));
        output_.append(reset);
        output_.push_back('\n');
        start = end + 1;
      }
    }

    // Text with control characters dropped and tabs expanded to spaces.
    void appendClean(std::string_view text) {
      for (std::size_t index = 0; index < text.size();) {
        const auto begin = index;
        const auto value = next(text, index);
        if (value == '\t') {
          output_.append("    ");
        } else if (!control(value)) {
          output_.append(text.substr(begin, index - begin));
        }
      }
    }

    void rule(const Block& block) {
      const auto used = prefix(block, true);

      output_.append("\x1b[2m");
      for (std::size_t column = 0; column < available(used); ++column) {
        output_.append("─");
      }

      output_.append(reset);
      output_.push_back('\n');
    }

    std::size_t cellWidth(const Cell& cell) const noexcept {
      std::size_t width = 0;

      for (const auto& run : document_.runsOf(cell)) {
        width += displayWidth(document_.view(run.text));
      }

      return width;
    }

    void table(const Block& block) {
      const auto cells = document_.cellsOf(block);
      const std::size_t columns_count = block.columns;
      std::array<std::size_t, 64> widths{};
      const auto shown = std::min<std::size_t>(columns_count, widths.size());

      for (std::size_t index = 0; index < cells.size(); ++index) {
        const auto column = index % columns_count;
        if (column < shown) {
          widths[column] = std::max(widths[column], cellWidth(cells[index]));
        }
      }

      Block plain = block;

      plain.marker = Marker::none;
      const auto used = std::size_t{plain.quote} * 2 + std::size_t{plain.list} * list_indent;
      const auto room = available(used);
      const auto borders = shown * 3 + 1;
      std::size_t total = 0;

      for (std::size_t column = 0; column < shown; ++column) {
        widths[column] = std::max<std::size_t>(widths[column], 1);
        total += widths[column];
      }

      // Shrink the widest columns until the table fits.
      while (total + borders > room && total > shown) {
        auto widest = std::max_element(widths.begin(), widths.begin() + static_cast<std::ptrdiff_t>(shown));

        --*widest;
        --total;
      }

      const auto line = [&](std::string_view left, std::string_view middle, std::string_view right) {
        prefix(plain, false);
        output_.append("\x1b[2m");
        output_.append(left);
        for (std::size_t column = 0; column < shown; ++column) {
          for (std::size_t count = 0; count < widths[column] + 2; ++count) {
            output_.append("─");
          }

          output_.append(column + 1 == shown ? right : middle);
        }

        output_.append(reset);
        output_.push_back('\n');
      };

      line("┌", "┬", "┐");
      const auto rows = cells.size() / columns_count;

      for (std::size_t row = 0; row < rows; ++row) {
        prefix(plain, false);
        for (std::size_t column = 0; column < shown; ++column) {
          output_.append("\x1b[2m│\x1b[0m ");
          const auto& cell = cells[row * columns_count + column];

          cellText(cell, widths[column], row == 0 ? style::strong : 0);
          output_.push_back(' ');
        }

        output_.append("\x1b[2m│\x1b[0m\n");
        if (row == 0 && rows > 1) {
          line("├", "┼", "┤");
        }
      }

      line("└", "┴", "┘");
    }

    // One cell on one line, aligned and cut to width with an ellipsis.
    void cellText(const Cell& cell, std::size_t width, std::uint32_t base) {
      const auto natural = cellWidth(cell);
      const auto shown = std::min(natural, width);
      const auto gap = width - shown;
      const auto before = cell.align == Align::right ? gap : cell.align == Align::center ? gap / 2
                                                                                         : 0;

      output_.append(before, ' ');
      std::size_t column = 0;
      const bool cut = natural > width;
      const auto budget = cut ? width - 1 : width;
      std::uint32_t current = 0;

      for (const auto& run : document_.runsOf(cell)) {
        setStyle(current, base | run.style);
        const auto text = document_.view(run.text);

        for (std::size_t index = 0; index < text.size();) {
          const auto begin = index;
          const auto value = next(text, index);
          const auto cells = columns(value);
          if (column + cells > budget) {
            break;
          }

          if (!control(value)) {
            output_.append(text.substr(begin, index - begin));
          } else {
            output_.push_back(' ');
          }

          column += cells;
        }
      }

      setStyle(current, 0);
      if (cut) {
        output_.append("…");
        ++column;
      }

      output_.append(width > column + before ? width - column - before : 0, ' ');
    }

    const Document<Memory>& document_;
    std::size_t width_;
    String<Output>& output_;
    String<Output> destination_;
  };

  template <Allocator Memory, Allocator Output>
  void render(const Document<Memory>& document, std::uint16_t width, String<Output>& output) {
    Painter<Memory, Output>{document, std::max(width, min_width), output}.paint();
  }

}
