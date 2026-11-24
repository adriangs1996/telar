module telar.gui.features.prompt;

import std;

import telar.gui.foundation.text;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::features::prompt {

  Layout::Layout(Memory& memory)
      : runs(memory),
        selection(memory) {}

  void classify(std::string_view text, std::span<Style> styles, ds::Vec<shell::Token, Memory>& tokens, shell::Syntax syntax) {
    std::ranges::fill(styles, Style::plain);
    tokens.resize(text.size() + 1);
    const auto lexed = shell::lex(text, syntax, tokens.viewMut());
    static constexpr ds::Array<std::string_view, 7> wrappers{"sudo", "env", "exec", "time", "command", "nohup", "doas"};
    std::uint32_t wrapped = shell::no_command;

    for (const auto& token : tokens.view().first(lexed.tokens)) {
      Style style = Style::plain;
      const auto word = text.substr(token.begin, token.end - token.begin);

      switch (token.kind) {
      case shell::TokenKind::command:
        style = Style::command;
        wrapped = std::ranges::find(wrappers, word) != wrappers.end() ? token.command : shell::no_command;
        break;
      case shell::TokenKind::argument:
        if (token.command == wrapped && (token.flags & shell::Token::word_start) != 0 && !word.starts_with('-') && !word.contains('=')) {
          style = Style::command;
          wrapped = std::ranges::find(wrappers, word) != wrappers.end() ? token.command : shell::no_command;
        } else if (word.contains('/') && !word.starts_with('-')) {
          style = Style::path;
        }

        break;
      case shell::TokenKind::option:
        style = Style::option;
        break;
      case shell::TokenKind::keyword:
        style = Style::keyword;
        break;
      case shell::TokenKind::string:
      case shell::TokenKind::heredoc_body:
        style = Style::string;
        break;
      case shell::TokenKind::variable:
      case shell::TokenKind::assignment:
        style = Style::variable;
        break;
      case shell::TokenKind::substitution:
      case shell::TokenKind::control:
      case shell::TokenKind::redirection:
        style = Style::shell_operator;
        break;
      case shell::TokenKind::comment:
        style = Style::comment;
        break;
      case shell::TokenKind::error:
        style = Style::error;
        break;
      }

      for (auto position = token.begin; position < token.end && position < styles.size(); ++position) {
        styles[position] = style;
      }
    }
  }

  bool incomplete(Memory& memory, std::string_view text, shell::Syntax syntax) {
    ds::Vec<shell::Token, Memory> tokens{memory};

    tokens.resize(text.size() + 1);
    return shell::lex(text, syntax, tokens.viewMut()).completeness != shell::Completeness::complete;
  }

  namespace {

    void reset(Layout& result) {
      result.runs.clear();
      result.selection.clear();
      result.rows = 1;
      result.width = Layout::indent;
      result.caret_row = 0;
      result.caret_column = Layout::indent;
      result.caret_columns = 1;
    }

    void placeCaret(Layout& result, CellRange cell) {
      result.caret_row = cell.row;
      result.caret_column = cell.column;
      result.caret_columns = std::max<std::uint32_t>(1, cell.columns);
    }

    // Adds `cell` to the selection, extending its last range when `cell` continues it.
    void select(Layout& result, CellRange cell) {
      auto& selection = result.selection;
      if (!selection.empty() && selection.back().row == cell.row && selection.back().column + selection.back().columns == cell.column) {
        selection.backMut().columns += cell.columns;
      } else if (selection.size() < Layout::maximum_runs) {
        selection.push(cell);
      }
    }

    // Adds `run` to the runs, extending the last one when `run` continues it in its style and group.
    void addRun(Layout& result, Run run) {
      auto& runs = result.runs;
      if (!runs.empty() && runs.back().row == run.row && runs.back().style == run.style && runs.back().group == run.group && runs.back().end == run.start) {
        runs.backMut().end = run.end;
        runs.backMut().columns += run.columns;
      } else if (runs.size() < Layout::maximum_runs) {
        runs.push(run);
      }
    }

  }

  namespace {

    struct CharacterRange {
      std::uint32_t first;
      std::uint32_t last;
    };

    // The bidi controls and zero-width characters a pasted command can hide behind: the zero
    // width joiners, which emoji sequences need, are left out.
    constexpr ds::Array<CharacterRange, 7> hidden_characters{
        {
            {.first = 0x61c, .last = 0x61c},
            {.first = 0x200b, .last = 0x200b},
            {.first = 0x200e, .last = 0x200f},
            {.first = 0x202a, .last = 0x202e},
            {.first = 0x2060, .last = 0x2064},
            {.first = 0x2066, .last = 0x2069},
            {.first = 0xfeff, .last = 0xfeff},
        },
    };

    // A UTF-8 sequence of two or three bytes, the lengths the hidden characters take: the bits
    // that mark its lead byte and those of the character it carries.
    struct Sequence {
      std::size_t bytes;
      unsigned lead_mask;
      unsigned lead_bits;
      unsigned payload;
    };

    constexpr ds::Array<Sequence, 2> hidden_sequences{
        {
            {.bytes = 2, .lead_mask = 0xe0, .lead_bits = 0xc0, .payload = 0x1f},
            {.bytes = 3, .lead_mask = 0xf0, .lead_bits = 0xe0, .payload = 0x0f},
        },
    };

    constexpr unsigned continuation_payload = 0x3fU;
    constexpr unsigned continuation_shift = 6U;

    // The code point, when `grapheme` is one of the hidden characters.
    ds::Option<std::uint32_t> hiddenCharacter(std::string_view grapheme) noexcept {
      for (const auto& sequence : hidden_sequences) {
        if (grapheme.size() != sequence.bytes || (static_cast<unsigned char>(grapheme.front()) & sequence.lead_mask) != sequence.lead_bits) {
          continue;
        }

        std::uint32_t character = static_cast<unsigned char>(grapheme.front()) & sequence.payload;

        for (const auto byte : std::span{grapheme}.subspan(1)) {
          character = (character << continuation_shift) | (static_cast<unsigned char>(byte) & continuation_payload);
        }

        if (std::ranges::any_of(hidden_characters, [character](const CharacterRange& range) {
              return character >= range.first && character <= range.last;
            })) {
          return character;
        }

        return ds::none;
      }

      return ds::none;
    }

    // Each grapheme of `text` laid out in rows of `columns` cells: `visit(start, end, cell,
    // newline)`. The row and column after the last.
    template <typename Visit>
    CellRange walk(std::string_view text, std::uint32_t columns, Visit visit) {
      std::uint32_t row = 0;
      std::uint32_t column = Layout::indent;
      GraphemeCursor graphemes{text};
      std::size_t offset = 0;

      while (true) {
        const auto start = offset;
        const auto grapheme = graphemes.nextReplacingInvalid();
        if (!grapheme) {
          break;
        }

        offset = graphemes.position();
        if (text[start] == '\n') {
          visit(start, offset, CellRange{.row = row, .column = column, .columns = 1}, true);
          ++row;
          column = Layout::indent;
          continue;
        }

        // A hidden character takes the cells of the mark the view draws for it.
        const auto width = hiddenCharacter(*grapheme) ? hidden_mark_columns : static_cast<std::uint32_t>(graphemes.columns());
        if (column + width > columns) {
          ++row;
          column = Layout::indent;
        }

        visit(start, offset, CellRange{.row = row, .column = column, .columns = width}, false);
        column += width;
      }

      return {.row = row, .column = column};
    }

    // The first and last rows a layout keeps. A text of fewer bytes than the runs it holds fits
    // whole; a longer one keeps the rows around the caret's, which a first walk finds.
    // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): the width it lays out in, then the caret's byte
    std::pair<std::uint32_t, std::uint32_t> keptRows(std::string_view text, std::uint32_t columns, std::size_t cursor) {
      if (text.size() <= Layout::maximum_runs) {
        return {0, std::numeric_limits<std::uint32_t>::max()};
      }

      ds::Option<std::uint32_t> caret_row;
      const auto end = walk(text, columns, [&](std::size_t start, std::size_t finish, CellRange cell, bool) {
        if (!caret_row && cursor >= start && cursor < finish) {
          caret_row = cell.row;
        }
      });

      const auto caret = caret_row.valueOr(end.column >= columns ? end.row + 1 : end.row);

      return {caret > Layout::kept_rows ? caret - Layout::kept_rows : 0, caret + Layout::kept_rows};
    }
  }

  void layout(Layout& result, const StyledText& styled, Selection selection, std::uint32_t columns) {
    const auto& [text, styles, groups] = styled;
    const auto cursor = selection.cursor;
    const auto anchor = selection.anchor;

    reset(result);

    columns = std::max<std::uint32_t>(columns, Layout::indent + 1);
    const auto selection_start = selection.range ? selection.range->first : std::min(cursor, anchor);
    const auto selection_end = selection.range ? selection.range->second : std::max(cursor, anchor);

    const auto [first_kept, last_kept] = keptRows(text, columns, cursor);

    // A hidden character is drawn as its mark, whatever style its bytes have.
    const auto style = [&](std::string_view grapheme, std::size_t start) {
      if (hiddenCharacter(grapheme)) {
        return Style::hidden;
      }

      return start < styles.size() ? styles[start] : Style::plain;
    };

    const auto end = walk(text, columns, [&](std::size_t start, std::size_t finish, CellRange cell, bool newline) {
      const bool kept = cell.row >= first_kept && cell.row <= last_kept;

      // A caret inside a grapheme, as one an accent written apart follows, is drawn on it.
      if (cursor >= start && cursor < finish) {
        placeCaret(result, cell);
      }

      if (kept && start >= selection_start && start < selection_end) {
        select(result, cell);
      }

      if (newline) {
        return;
      }

      if (kept) {
        addRun(
            result,
            Run{
                .row = cell.row,
                .column = cell.column,
                .columns = cell.columns,
                .start = start,
                .end = finish,
                .style = style(text.substr(start, finish - start), start),
                .group = start < groups.size() ? groups[start] : std::uint8_t{0},
            }
        );
      }

      result.width = std::max(result.width, cell.column + cell.columns);
    });

    auto row = end.row;
    auto column = end.column;

    if (cursor >= text.size()) {
      if (column >= columns) {
        ++row;
        column = Layout::indent;
      }

      placeCaret(result, CellRange{.row = row, .column = column, .columns = 1});
    }

    result.rows = row + 1;
    result.width = std::max(result.width, std::min(columns, result.caret_column + 1));
  }

  void hiddenMarks(std::string_view text, ds::String<Memory>& out) {
    GraphemeCursor graphemes{text};
    std::size_t offset = 0;

    while (const auto grapheme = graphemes.nextReplacingInvalid()) {
      if (const auto character = hiddenCharacter(text.substr(offset, graphemes.position() - offset))) {
        out.append(ds::format(out.memory(), "⟨U+{:04X}⟩", *character));
      }

      offset = graphemes.position();
    }
  }

}
