export module telar.gui.prompt.layout;

import std;

export import telar.shell.syntax;

// Places the command on the line's cell grid: runs of one style per row, wrapping at the
// line's width so nothing is ever cut, and where the caret and the selection fall. Pure, so
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
  // variables, operators, keywords and comments. A command is one while it is still being typed,
  // as the shell's own highlighting shows it: whether it exists is the editor's to mark.
  void classify(std::string_view text, std::span<Style> styles, shell::Syntax syntax = {});

  // Whether the shell would read more lines before running `text`.
  bool incomplete(std::string_view text, shell::Syntax syntax = {});

  // Lays out `text` in rows of `columns` cells. `styles` holds one style per byte and `groups`,
  // when given, the animation each byte takes part in: a run never spans two.
  Layout layout(std::string_view text, std::span<const Style> styles, std::size_t cursor, std::size_t anchor, std::uint32_t columns, std::span<const std::uint8_t> groups = {});

}
