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

## Commit style

When writing commit messages, descriptions or PRs:

- Do not add a footnote with model signature:

```
// BAD
Co-Authored-By: <Model>
```
