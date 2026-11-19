module telar.gui.features.prompt;

import std;

import telar.gui.foundation.text;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::features::prompt {

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
        style = Style::operator_;
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

  void layout(Layout& result, std::string_view text, std::span<const Style> styles, std::size_t cursor, std::size_t anchor, std::uint32_t columns, std::span<const std::uint8_t> groups) {
    result.runs.clear();
    result.selection.clear();
    result.rows = 1;
    result.width = Layout::indent;
    result.caret_row = 0;
    result.caret_column = Layout::indent;
    result.caret_columns = 1;

    columns = std::max<std::uint32_t>(columns, Layout::indent + 1);
    std::uint32_t row = 0;
    std::uint32_t column = Layout::indent;
    const auto selection_start = std::min(cursor, anchor);
    const auto selection_end = std::max(cursor, anchor);
    const auto caret = [&](std::size_t offset, std::uint32_t at_row, std::uint32_t at_column, std::uint32_t width) {
      if (offset == cursor) {
        result.caret_row = at_row;
        result.caret_column = at_column;
        result.caret_columns = std::max<std::uint32_t>(1, width);
      }
    };

    const auto select = [&](std::size_t offset, std::uint32_t at_row, std::uint32_t at_column, std::uint32_t width) {
      if (offset < selection_start || offset >= selection_end) {
        return;
      }

      if (!result.selection.empty() && result.selection.back().row == at_row && result.selection.back().column + result.selection.back().columns == at_column) {
        result.selection.backMut().columns += width;
      } else if (result.selection.size() < Layout::maximum_runs) {
        result.selection.push({at_row, at_column, width});
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
        caret(start, row, column, 1);
        select(start, row, column, 1);
        ++row;
        column = Layout::indent;
        continue;
      }

      const auto width = static_cast<std::uint32_t>(graphemes.columns());
      if (column + width > columns) {
        ++row;
        column = Layout::indent;
      }

      caret(start, row, column, width);
      select(start, row, column, width);
      const auto style = start < styles.size() ? styles[start] : Style::plain;
      const auto group = start < groups.size() ? groups[start] : std::uint8_t{0};
      auto& runs = result.runs;
      if (!runs.empty() && runs.back().row == row && runs.back().style == style && runs.back().group == group && runs.back().end == start) {
        runs.backMut().end = offset;
        runs.backMut().columns += width;
      } else if (runs.size() < Layout::maximum_runs) {
        runs.push({row, column, width, start, offset, style, group});
      }

      column += width;
      result.width = std::max(result.width, column);
    }

    if (cursor >= text.size()) {
      if (column >= columns) {
        ++row;
        column = Layout::indent;
      }

      result.caret_row = row;
      result.caret_column = column;
      result.caret_columns = 1;
    }

    result.rows = row + 1;
    result.width = std::max(result.width, std::min(columns, result.caret_column + 1));
  }

}
