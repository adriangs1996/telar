export module telar.shell.syntax;

import std;

// Lexes and segments an interactive command line in one linear pass. Nothing
// allocates: tokens, words and unquoted text land in caller buffers, and a full
// buffer is reported instead of grown.
export namespace telar::shell {

  enum class Dialect : std::uint8_t {
    posix, // bash and zsh
    fish,
  };

  struct Syntax {
    Dialect dialect = Dialect::posix;
    // zsh reads # as a word character unless INTERACTIVE_COMMENTS is set.
    bool comments = true;
  };

  enum class TokenKind : std::uint8_t {
    // Literal parts of a word take the role of the word.
    command,
    argument,
    option,
    keyword,
    assignment,
    // Parts of a word with their own colour; Token::role keeps the word's role.
    string,
    variable,
    substitution,
    // Never part of a word.
    control,
    redirection,
    comment,
    heredoc_body,
    error,
  };

  enum class Quote : std::uint8_t {
    none,
    single_quoted,
    double_quoted,
    ansi_c,
  };

  inline constexpr std::uint32_t no_command = std::numeric_limits<std::uint32_t>::max();
  inline constexpr std::size_t no_cursor = std::numeric_limits<std::size_t>::max();
  inline constexpr std::size_t no_word = std::numeric_limits<std::size_t>::max();
  // Beyond these limits the lexer fails closed: the rest of the line is one error
  // token and the line is reported as Completeness::limit.
  inline constexpr std::size_t max_line = std::numeric_limits<std::uint32_t>::max() - 1;
  inline constexpr std::size_t max_depth = 64;
  inline constexpr std::size_t max_heredocs = 8;
  inline constexpr std::size_t max_delimiter = 128;

  // Tokens cover the line in order without overlapping; blanks between words have
  // no token. A word is a run of tokens of one command, the first with word_start;
  // tokens of a nested command (inside $(...)) may sit between its parts.
  struct Token {
    static constexpr std::uint8_t word_start = 1;
    static constexpr std::uint8_t redirect_target = 2;
    // A quote or heredoc body the line ends inside.
    static constexpr std::uint8_t unterminated = 4;

    std::uint32_t begin = 0;
    std::uint32_t end = 0;
    // The simple command the token belongs to, numbered in line order;
    // no_command for control operators, comments, heredoc bodies and errors.
    std::uint32_t command = no_command;
    TokenKind kind = TokenKind::error;
    TokenKind role = TokenKind::error;
    Quote quote = Quote::none;
    std::uint8_t flags = 0;
  };

  // Whether Enter submits the line or continues it, and why.
  enum class Completeness : std::uint8_t {
    complete,
    open_quote,
    trailing_escape,
    open_substitution, // $( ${ $(( ` <( >( =( and fish ( $(
    open_group,        // ( and { groups, name=( arrays
    open_compound,     // if, loops, case, [[, ((, fish blocks, a function without a body
    pending_heredoc,
    trailing_operator, // | |& && ||
    limit,
  };

  struct Lexed {
    std::size_t tokens = 0;
    std::uint32_t commands = 0;
    Completeness completeness = Completeness::complete;
    // The token buffer filled; tokens is its size. Every other field stays exact.
    bool overflow = false;
    // The cursor lies in a command: false inside comments and heredoc bodies,
    // past the line, or when no cursor was given.
    bool cursor_completable = false;
    // no_command while the cursor starts a command that has no words yet.
    std::uint32_t cursor_command = no_command;
    // The cursor, moved back to the first byte of the UTF-8 sequence it split.
    std::size_t cursor = no_cursor;
  };

  // tokens.size() >= line.size() guarantees no overflow.
  [[nodiscard]] Lexed lex(std::string_view line, Syntax syntax, std::span<Token> tokens,
                          std::size_t cursor = no_cursor) noexcept;

  struct Range {
    std::uint32_t begin = 0;
    std::uint32_t end = 0;
  };

  struct Segment {
    Range source;
    // Token indexes [first_token, end_token) hold the command's tokens and those
    // of the commands nested in it; filter by Token::command.
    std::uint32_t first_token = 0;
    std::uint32_t end_token = 0;
  };

  // Writes one segment per command id; returns how many commands the tokens hold,
  // which exceeds segments.size() when the buffer is short.
  [[nodiscard]] std::size_t segment(std::span<const Token> tokens, std::span<Segment> segments) noexcept;

  struct Word {
    Range source;
    // Quotes and escapes removed; expansions and substitutions kept verbatim.
    std::string_view text;
    TokenKind role = TokenKind::argument;
    std::uint8_t flags = 0; // Token::redirect_target
  };

  struct CommandAt {
    std::size_t words = 0;
    std::size_t command_word = no_word;
    // The word the cursor touches, or the index a word typed there would take.
    std::size_t current = no_word;
    bool in_word = false;
    // words or text was too small, or tokens do not belong to line; the other
    // fields are not meaningful.
    bool overflow = false;
    // Source bytes a completion replaces: the current word, or empty at the cursor.
    Range replace;
    // Unquoted text of the current word before the cursor.
    std::string_view prefix;
  };

  // The words of the simple command at lexed.cursor. tokens must be the ones
  // lex() produced for line. words.size() >= line.size() and
  // text.size() >= 2 * line.size() guarantee no overflow.
  [[nodiscard]] CommandAt commandAt(std::string_view line, Syntax syntax, std::span<const Token> tokens,
                                    const Lexed &lexed, std::span<Word> words, std::span<char> text) noexcept;

}
