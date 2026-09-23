---
status: accepted
---

# Keep each process's state in one flat model

Telar's state was a hierarchy. A client reached a pane through five hops
(`model.workspace.activeConst().?.model.findConst(id)`), a runtime frame was
looked up three times on its way to the pane, and branches that needed each
other copied data across (a tab's foreground name, the runtime agent beside
its pane) or held pointers back to their owner. Rules that required one type
per file, at most three parameters, public-file capability lists and ports for
every host service multiplied the pieces: 1,618 of 3,000 files had fewer than
20 lines, 33 context structs existed to pass parameters, and the shared client
had 21 function-pointer ports, 19 of them unset until bound.

## Decision

Each process keeps its state in one flat struct, `RuntimeModel` or
`ClientModel`. Singletons are fields. Repeating entities live in tables of
columns indexed by slot, with an id index. Relations are ids or slots, never
pointers or nesting. Behavior is procedures over the model, grouped by flow and
named after `docs/flows`. Each process dispatches every message through one
`update` and flushes once afterwards. Host facts enter the model as data and
host requests leave it as data; adapters drain them with exhaustive switches.

Details: [architecture](../architecture.md), [naming](../naming.md).

## Considered options

- A tree of structs that each encapsulate their state reproduces the problem:
  a reference between branches breaks the encapsulation, the tree is hard to
  lay out in memory, and a reader follows ownership instead of data.
- A general entity-component framework adds machinery the problem does not
  need. Tables are plain arrays with a count and the existing slot index.
- Rewriting both processes from scratch would lose behavior recorded only in
  code and in 3,786 tests. The code migrates by flow, each step deleting the
  old path.

## Consequences

Any code can read any column, so writes follow a convention rather than
encapsulation: tables own only their structural changes, flow procedures write
columns, and a `debugCheck` in tests verifies cross-table invariants. Ids stay
mandatory across asynchronous work. Superseded decisions about capabilities,
request controllers, presentation versions, shared adapters, file layout and
direct operations were removed; the [invariants](../invariants.md) keep what
still protects users.
