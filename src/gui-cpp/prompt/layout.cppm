module;
#include <cstddef>
#include <cstdint>

export module telar.gui.prompt.layout;

import std;

export import telar.gui.text.bounded_editor;
export import telar.shell.syntax;

// Places the command on the island's cell grid: runs of one style per row, wrapping at the
// island's width so nothing is ever cut, and where the caret and the selection fall. Pure, so
// the view repaints from it and tests check it.
export namespace telar::gui::prompt {

enum class Style : std::uint8_t {
  plain,
  command,
  option,
  string,
  variable,
  operator_,
  keyword,
  comment,
  pending,
  error,
  // The rest of a suggested command, after the caret.
  ghost,
  // An argument naming a file, and a command the shell does not run.
  path,
  missing,
};

struct Run {
  std::uint32_t row = 0;
  std::uint32_t column = 0;
  std::uint32_t columns = 0;
  std::size_t start = 0;
  std::size_t end = 0;
  Style style = Style::plain;
  // The animation the run's text takes part in, 0 for none.
  std::uint8_t group = 0;
};

struct CellRange {
  std::uint32_t row = 0;
  std::uint32_t column = 0;
  std::uint32_t columns = 0;
};

struct Layout {
  // The prompt mark takes the first columns of every row, so wrapped lines align with it.
  static constexpr std::uint32_t indent = 2;
  static constexpr std::size_t maximum_runs = 4096;

  std::vector<Run> runs;
  std::vector<CellRange> selection;
  std::uint32_t rows = 1;
  // The widest row, in cells, the mark included.
  std::uint32_t width = indent;
  std::uint32_t caret_row = 0;
  std::uint32_t caret_column = indent;
  std::uint32_t caret_columns = 1;
};

// Colours the command the way its shell reads it, from the shell lexer: the command of each
// simple command (and the one a wrapper such as sudo runs), options, quoted strings,
// variables, operators, keywords and comments. A command still being typed at the end of the
// line is pending until a blank ends it, so its colour does not flicker while typing.
inline void classify(std::string_view text, std::span<Style> styles, shell::Syntax syntax = {}) {
  std::ranges::fill(styles, Style::plain);
  thread_local std::vector<shell::Token> tokens;
  tokens.resize(text.size() + 1);
  const auto lexed = shell::lex(text, syntax, tokens);
  static constexpr std::array<std::string_view, 7> wrappers{"sudo", "env", "exec", "time", "command", "nohup", "doas"};
  std::uint32_t wrapped = shell::no_command;
  for (const auto &token : std::span{tokens}.first(lexed.tokens)) {
    Style style = Style::plain;
    const auto word = text.substr(token.begin, token.end - token.begin);
    switch (token.kind) {
    case shell::TokenKind::command:
      style = token.end == text.size() ? Style::pending : Style::command;
      wrapped = std::ranges::find(wrappers, word) != wrappers.end() ? token.command : shell::no_command;
      break;
    case shell::TokenKind::argument:
      if (token.command == wrapped && (token.flags & shell::Token::word_start) != 0 && !word.starts_with('-') && word.find('=') == std::string_view::npos) {
        style = token.end == text.size() ? Style::pending : Style::command;
        wrapped = std::ranges::find(wrappers, word) != wrappers.end() ? token.command : shell::no_command;
      } else if (word.find('/') != std::string_view::npos && !word.starts_with('-')) {
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

// Whether the shell would read more lines before running `text`.
inline bool incomplete(std::string_view text, shell::Syntax syntax = {}) {
  thread_local std::vector<shell::Token> tokens;
  tokens.resize(text.size() + 1);
  return shell::lex(text, syntax, tokens).completeness != shell::Completeness::complete;
}

// Lays out `text` in rows of `columns` cells. `styles` holds one style per byte and `groups`,
// when given, the animation each byte takes part in: a run never spans two.
inline Layout layout(std::string_view text, std::span<const Style> styles, std::size_t cursor, std::size_t anchor, std::uint32_t columns, std::span<const std::uint8_t> groups = {}) {
  Layout result;
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
      result.selection.back().columns += width;
    } else if (result.selection.size() < Layout::maximum_runs) {
      result.selection.push_back({at_row, at_column, width});
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
    auto &runs = result.runs;
    if (!runs.empty() && runs.back().row == row && runs.back().style == style && runs.back().group == group && runs.back().end == start) {
      runs.back().end = offset;
      runs.back().columns += width;
    } else if (runs.size() < Layout::maximum_runs) {
      runs.push_back({row, column, width, start, offset, style, group});
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
  return result;
}

}
