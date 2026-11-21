# telar

telar is an alternative to tmux for the era of agents. It is heavily inspired
by herdr (<https://github.com/herdrdev/herdr>). It brings to the table
a full runtime aware of agents and types of process that enhance the user's
control over what is running in his terminal. At the heart, it reduces to these
general components:

- A terminal multiplexer
- A pty-proxy
- Searchable and structured history
- Best effort integration with coding agents.
- An innovative and modern GUI terminal emulator focused on user awareness.

## Architecture

Two processes. The split decides almost everything else, so get it right before
you add anything that crosses it.

A folder is a deep module: it is named for what it hides, and what is below it is its own
business. A folder that holds several domains (`src/runtime/traffic`, `src/cli/session`) is
sealed. Outside it you import only the modules its entry of `public_modules` lists in
`docs/build/modules.json`. When you need something it hides, ask whether the folder should do
that work for you before you make one more module public: the list is meant to shrink.

- Module graph, layers, public modules, test placement: `python3 tools/check-cpp-modules.py`
  checks them and its message names the rule and the file. Run it after you add, move or
  import a module.
- Moving or renaming a domain: `tools/move-cpp-domain.py --help`. A module is named by its
  path, so the tool renames it in every importer, with its target and its test label.
- A function body in a `.cppm`: read "Interface bodies" in `lib/tbc/README.md` first. A body
  stays in an interface only as `TBC_HOT_PATH` or `TBC_GENERIC`.
- Adding a request to the protocol or a use case to the window, with every place it touches
  and what fails when you miss one: `docs/build/recipes.md`.
- One case of the window test in two seconds, where the whole program takes eighty:
  `just gui-case <case>`; `just gui-case -functions` lists the cases.
- The tests of the one domain or library you changed, building only them: `just domain-test <label>`,
  with the label its cases carry, `runtime.terminal` or `lib.base`.
- Run one `ctest` at a time in a build tree: two at once corrupt the lists of cases it
  discovers.
- Toolchain, configure, build and test commands: `docs/build/cpp-modules.md`.
- The GUI's layers and what a feature exports: `docs/build/gui-architecture.md`.

## Performance, no matter what

Doing so much work and placing between the terminal emulator and the actual pty,
adds latency. Users should not note that telar is proxying their requests, so,
functions should be heavily optimized. Strive to be obsessive about memory allocation
control, and the amount of work being done everywhere. Do heavy use of caching, compile time
processing, and every single idea that could save from running expensive or more instructions
than needed. The best work is the one we don't do.

## Safety

telar runs continuously on user's devices, and might be used in a remote server,
so security is not negotiable. Prefer secure code over pretty or convenient code.
Watch out for memory problems. Take inspiration from Rust for keeping track of memory.

## Glossary

- you means the agent reading this file and changing telar.
- me is who you are talking to.
- user means the person using telar.
- agent means the coding agent a user runs inside a telar's pane. It could include you.
- client means the window (GUI) or the headless client connected to telar's runtime.

## Behaviors you follow

- Strive to test only what is being changed. Full test suite are expensive,
  leave them for when a change could affect many flows

- Do not include features that will only work on my local environment. Every
  feature must be thought in the context of a generic user, not just on my
  current environment. My current environment can be used as guideline and
  playground for testing if an approach works, but there should not be any
  hardcoded functionality that just works on my local environment.

- DO NOT SCOPE CREEP. Keep tasks scoped to what the user ask for.

- Tests: a test lives with what it checks, in `<process>/<domain>/tests/` or
  `lib/<library>/tests/`, a GUI test of `src/gui/ui` in the `ui/` folder whose
  headers it includes, and only one that crosses domains goes in
  `<process>/tests/`; `tools/check-cpp-modules.py` names the right folder. A C++
  case registers with `telar.testing` (`lib/testing/testing.cppm`; a QtTest slot
  through `src/gui/tests/qt_case.hpp`) and runs as its own CTest test,
  `<label>.<suite>.<case>`: select by label (`ctest -L '^runtime\.terminal$'`), or
  one case with `-R`. Probes and benchmarks are tools, in `<process>/tools/`.

- Code layout: before writing or editing C++, read `docs/code-style.md`. It covers
  line breaks, trailing commas and blank lines between logical blocks.

## Commit style

When writing commit messages, descriptions or PRs:

- Do not add a footnote with model signature:

```
// BAD
Co-Authored-By: <Model>
```
