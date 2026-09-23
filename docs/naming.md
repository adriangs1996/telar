# Naming

A name tells the reader what happens without opening the function. These four
rules apply to every new or migrated file, type, function and field.

## 1. Names come from the glossary and the flows

- Domain concepts use the term defined in [`CONTEXT.md`](../CONTEXT.md). A
  concept without a term gets one there first, then appears in code.
- A file of procedures is named after its flow in [`docs/flows`](flows/README.md):
  `pane_frame.zig` implements `docs/flows/pane-frame.md`. A reader of either
  finds the other by name.
- The process state is `ClientModel` or `RuntimeModel`, as the glossary
  defines them. The parameter is `model`.

## 2. A call reads as a sentence

A call is `flow.verb(model, object)`. The verb comes from a closed vocabulary,
and each verb tells the reader what kind of thing happens:

| Verb | Meaning |
| --- | --- |
| `request` | sends a request to the runtime; the answer arrives later through `receive` |
| `receive` | a runtime message arrives and updates the client's replica |
| `start` / `finish` | launches a worker or timer / takes its completion |
| `enter` / `leave` | enters or leaves an input mode |
| a domain verb: `focus`, `split`, `rename`, `move`, `scroll`, `select`, `show`, `hide` | a local change that happens now |

`apply`, `handle`, `process`, `execute`, `perform`, `run`, `do`, `manage` and
`sync` say only that something happens, so they are not used. The single
dispatch function of each process is `update`.

```zig
try tab_rename.request(model, tab, label);  // goes to the runtime; the reply comes through receive
try pane_focus.move(model, .left);          // local, no network
try copy_mode.enter(model, pane);           // changes the input mode
try config_reload.start(model);             // launches the worker
```

One flow has one name at every layer. A key press is `input_routing.route`,
then `pane_input.send`; it is not five `route*` functions that differ only in
how much they already know.

## 3. Tables, columns and identities

- A table is a plural domain noun: `tabs`, `panes`, `agents`, `layouts`. Its
  type has the same name in PascalCase: `Panes`.
- A column is the plain field name: `model.panes.cursor[slot]`, not
  `pane_cursor` or `getCursor()`.
- Identities and slots are distinct types. `PaneId` crosses processes and
  asynchronous work; `PaneSlot` indexes a table inside one call. The compiler
  rejects one where the other belongs.
- Queues name their direction: `model.to_runtime`, `model.to_host`.

## 4. No empty names

- No `*Type` aliases: import the type under its own name.
- No `Context`, `Manager`, `Helper`, `Support`, `Utils`, `Info` or `Data`, and
  no bare `State`, `Entry`, `Item` or `Record`. Say what it holds.
- `Model` names only the process state.
- A return type is named for the question it answers. `pane_frame.receive`
  returns a `FrameReceipt` of `.accepted`, `.detached` or `.needs_snapshot`,
  not a `PaneFrameOutcome` with an `.applied` case.
