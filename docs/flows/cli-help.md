# CLI help

`--help` (or `-h`) on a `telar` command line is answered by the binary alone:
no runtime is started or contacted, nothing runs, and the answer describes the
version that prints it. This is how a coding agent discovers telar instead of
memorizing it: the bundled skill (`telar --skill`) teaches the walk, and the
help carries every syntax, default and limit.

## Trigger

`src/cli/help.zig` `find` inspects the arguments before any grammar:

- `telar --help` is the root: a capability map of every command family
  (`CommandFamily`, `src/cli/arguments/CommandFamily.zig`), the window options,
  the pane environment and the default keybindings.
- `telar FAMILY --help` lists the family's commands with one line each and
  what they share (targets, ownership, exit codes).
- `telar FAMILY COMMAND --help` prints one command's usage, arguments,
  effects and results. Nested words (`proxy trust install`, `client open goto`)
  belong to the command named by the second word.
- A `--help` after `--` is the child command's: `telar worktree exec fix --
  claude --help` runs Claude with `--help`. A first word that is no family is a
  program for a pane, whose `--help` is its own.

`Cli.parse` returns `.help` with a `HelpTopic`, which `main` prints through
`help.run`. A command line the parser rejects ends with
`see telar FAMILY [COMMAND] --help`, as far as the words reached a known family
and command (`help.topic`).

## Source of truth

Each family owns one table in `src/cli/help/<family>.zig`: a `FamilyHelp` with
its `CommandHelp` rows. Help text derives changing limits from the constants
the grammar and the runtime enforce (`core.max_pane_text_rows`,
`ExitedPanes.kept_rows`, ...) through `comptimePrint`, so a raised bound
reprints itself. `help.family` is an exhaustive switch over `CommandFamily`:
a family without help does not compile, and the parser dispatches on the same
enum, so a family without a grammar does not either.

## Proof

- `src/cli/help.zig`: `find` at root, family and command depth and never after
  `--`; every family prints its usage and its visible commands; every command's
  usage names it; every example a command lists parses with `Cli.parse`.
- `src/cli/parser.zig`: every action enum of every grammar has a command help,
  and every routed `core.ClientAction` is claimed by exactly one command.
- `src/cli/skill.zig`: the skills name only commands the help knows and keep
  numeric limits out.
- `src/cli/integration/help.test.mjs`, against the built binary in a throwaway
  home: walks from the root to every command without knowing any name, checks
  nested words, unknown words, `--help` after `--`, and that no runtime
  directory appears.
