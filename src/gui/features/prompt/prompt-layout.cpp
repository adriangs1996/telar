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

    // The bidi controls and zero-width characters a pasted command can hide behind: the zero
    // width joiners, which emoji sequences need, are left out. The code point, when `grapheme` is
    // one of them.
    ds::Option<std::uint32_t> hiddenCharacter(std::string_view grapheme) noexcept {
      constexpr std::size_t three_bytes = 3;
      constexpr std::size_t two_bytes = 2;

      std::uint32_t character = 0;
      if (grapheme.size() == three_bytes && (static_cast<unsigned char>(grapheme[0]) & 0xf0U) == 0xe0U) {
        character = ((static_cast<unsigned char>(grapheme[0]) & 0x0fU) << 12U) | ((static_cast<unsigned char>(grapheme[1]) & 0x3fU) << 6U) | (static_cast<unsigned char>(grapheme[2]) & 0x3fU);
      } else if (grapheme.size() == two_bytes && (static_cast<unsigned char>(grapheme[0]) & 0xe0U) == 0xc0U) {
        character = ((static_cast<unsigned char>(grapheme[0]) & 0x1fU) << 6U) | (static_cast<unsigned char>(grapheme[1]) & 0x3fU);
      } else {
        return ds::none;
      }

      const bool hidden = character == 0x61c || character == 0x200b || character == 0x200e || character == 0x200f || (character >= 0x202a && character <= 0x202e) || (character >= 0x2060 && character <= 0x2064) || (character >= 0x2066 && character <= 0x2069) || character == 0xfeff;

      return hidden ? ds::Option{character} : ds::none;
    }

    // Each grapheme of `text` laid out in rows of `columns` cells: `visit(start, end, cell,
    // newline)`. The row and column after the last.
    template <typename Visit>
    CellRange walk(std::string_view text, std::uint32_t columns, Visit&& visit) {
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

  }

  void layout(Layout& result, const StyledText& styled, Selection selection, std::uint32_t columns) {
    const auto& [text, styles, groups] = styled;
    const auto cursor = selection.cursor;
    const auto anchor = selection.anchor;

    reset(result);

    columns = std::max<std::uint32_t>(columns, Layout::indent + 1);
    const auto selection_start = selection.range ? selection.range->first : std::min(cursor, anchor);
    const auto selection_end = selection.range ? selection.range->second : std::max(cursor, anchor);

    // A text of fewer bytes than the runs a layout keeps fits whole; a longer one keeps the rows
    // around the caret's, which a first walk finds.
    std::uint32_t first_kept = 0;
    std::uint32_t last_kept = std::numeric_limits<std::uint32_t>::max();

    if (text.size() > Layout::maximum_runs) {
      ds::Option<std::uint32_t> caret_row;
      const auto end = walk(text, columns, [&](std::size_t start, std::size_t finish, CellRange cell, bool) {
        if (!caret_row && cursor >= start && cursor < finish) {
          caret_row = cell.row;
        }
      });
      const auto caret = caret_row.valueOr(end.column >= columns ? end.row + 1 : end.row);

      first_kept = caret > Layout::kept_rows ? caret - Layout::kept_rows : 0;
      last_kept = caret + Layout::kept_rows;
    }

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
                .style = hiddenCharacter(text.substr(start, finish - start)) ? Style::hidden : (start < styles.size() ? styles[start] : Style::plain),
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
