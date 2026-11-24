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

  void layout(Layout& result, const StyledText& styled, Selection selection, std::uint32_t columns) {
    const auto& [text, styles, groups] = styled;
    const auto [cursor, anchor] = selection;

    reset(result);

    columns = std::max<std::uint32_t>(columns, Layout::indent + 1);
    std::uint32_t row = 0;
    std::uint32_t column = Layout::indent;
    const auto selection_start = std::min(cursor, anchor);
    const auto selection_end = std::max(cursor, anchor);
    // A caret inside a grapheme, as one an accent written apart follows, is drawn on it.
    const auto place = [&](std::size_t offset, std::size_t end, CellRange cell) {
      if (cursor >= offset && cursor < end) {
        placeCaret(result, cell);
      }

      if (offset >= selection_start && offset < selection_end) {
        select(result, cell);
      }
    };

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
        place(start, offset, CellRange{.row = row, .column = column, .columns = 1});
        ++row;
        column = Layout::indent;
        continue;
      }

      const auto width = static_cast<std::uint32_t>(graphemes.columns());
      if (column + width > columns) {
        ++row;
        column = Layout::indent;
      }

      place(start, offset, CellRange{.row = row, .column = column, .columns = width});
      addRun(
          result,
          Run{
              .row = row,
              .column = column,
              .columns = width,
              .start = start,
              .end = offset,
              .style = start < styles.size() ? styles[start] : Style::plain,
              .group = start < groups.size() ? groups[start] : std::uint8_t{0},
          }
      );
      column += width;
      result.width = std::max(result.width, column);
    }

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

}
