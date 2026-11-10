# telar-shell

Lexes and segments the command line a user is typing, for the native line
editor that replaces the line editors of zsh, bash and fish. One linear pass
over the line gives the tokens to highlight, whether Enter runs the line or
continues it, and the words of the simple command at the cursor for completion.
It is C++23 with one module interface, `telar.shell.syntax`, and no dependencies.

Nothing allocates. Tokens, words and unquoted text go into caller buffers; a
full buffer is reported, never grown. Buffers as large as the line never fill:
`tokens.size() >= line.size()`, `words.size() >= line.size()` and
`text.size() >= 2 * line.size()`. Every function is `noexcept`.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-shell" "${CMAKE_CURRENT_BINARY_DIR}/telar-shell")
target_link_libraries(your_target PRIVATE telar::shell)
```

```cpp
import telar.shell.syntax;
using namespace telar::shell;

std::array<Token, 1024> tokens;
const Syntax zsh{Dialect::posix, /*comments=*/false};
const Lexed lexed = lex(line, zsh, tokens, cursor);
for (const Token &t : std::span{tokens}.first(lexed.tokens)) {
  paint(t.begin, t.end, t.kind);
}
if (lexed.completeness != Completeness::complete) {
  insertNewline();
}
std::array<Word, 256> words;
std::array<char, 2048> text;
const CommandAt at = commandAt(line, zsh, tokens, lexed, words, text);
// words[at.command_word].text is the command name, at.prefix the typed part
// of words[at.current], and at.replace the bytes a completion replaces.
```

## Tokens

Tokens cover the line in order without overlapping; blanks have none. Literal
parts of a word take the word's role: `command`, `argument`, `option` (`-x`,
`--long=value`), `keyword` (reserved words in command position only) or
`assignment` (`FOO=bar cmd`, `a=(1 2)`). Quoted parts are `string` (with
`Token::quote`), `$x` and `${...}` are `variable`, `$(...)`, backticks, `<(...)`
and `$((...))` delimiters are `substitution`, and the nested command inside a
substitution has tokens of its own. `Token::role` keeps the word's role on every
part, so `--opt="$x"` paints as an option throughout. The rest are `control`
(`|` `|&` `||` `&&` `;` `;;` `&` newline `(` `)`), `redirection` (`>` `2>&1`
`<<-` `&>>` `>?` ...), `comment`, `heredoc_body` and `error` (stray closers,
`;;` outside `case`, and the tail past a limit).

A word is the run of tokens of one command starting with `Token::word_start`.
`Token::command` numbers simple commands in line order; `segment()` gives each
one's source range. A keyword joins the command that follows it, so `if git`
is one command whose words are `if` and `git`, with `git` as the command name.
A word the user is still typing is an ordinary word, so its colour holds while
typing; an unclosed quote keeps its kind and gets `Token::unterminated`.

## Enter

`Lexed::completeness` is `complete` or the innermost reason to continue:
`open_quote`, `trailing_escape`, `open_substitution`, `open_group` (`(`, `{`,
`a=(`), `open_compound` (`if`, loops, `case`, `[[`, `((`, fish blocks, a
function without a body), `pending_heredoc` and `trailing_operator` (`|`, `|&`,
`&&`, `||`, also before blank lines). Syntax errors are `complete`, so the shell
reports them. `limit` means the lexer stopped: more than 64 nested constructs,
more than 8 pending heredocs, or a delimiter over 128 bytes.

## Dialects

`Dialect::posix` covers bash and zsh: `$'...'` and `$"..."`, `${...}` with zsh
flags and nesting, `=(...)` and `<(...)`, glob groups such as `*(.om[1])` and
`@(a|b)` inside a word, `case` patterns, `[[ ]]` operators, `(( ))`, arrays,
heredocs with `<<-` and quoted delimiters, and zsh's `&!`, `&|`, `;|` and `>!`.
zsh without `INTERACTIVE_COMMENTS` reads `#` as a word character: pass
`comments = false`. `Dialect::fish` covers `\'` in single quotes, `$var[1]` and
`$$var`, `(cmd)` and `$(cmd)`, blocks closed by `end` (`else if` opens none),
`and`, `or`, `not`, `>?`, `&>` and `2>|` pipes. Unquoted text decodes fish's
`\n`, `\xHH` and `\uXXXX` escapes and ANSI-C escapes in `$'...'`.

Not handled: zsh `foreach`/`repeat` short forms and numeric globs `<1-10>`
(read as redirections), bash `{fd}>file`, `$((` is always arithmetic (bash
reparses `$((cmd) )` as a command substitution), `{` and `}` are word
characters in fish, a backtick inside double quotes inside backticks, and
expansions inside heredoc bodies, which are one token.

## Standalone checks

```sh
tools/cpp configure shell
tools/cpp build shell
tools/cpp test shell
tools/cpp configure shell -B lib/telar-shell/out-sanitize --sanitizers
tools/cpp configure shell -B lib/telar-shell/out-release --config Release
tools/cpp build shell -B lib/telar-shell/out-release
lib/telar-shell/out-release/telar-shell-bench
```

The tests are tables of lines and their expected tokens, verdicts, segments and
cursor words in both dialects, plus a fuzz pass over random and multibyte lines
that checks bounds, ordering, exact-size buffers and UTF-8 boundaries. Run it
under the sanitizer build too.
