# Recipes

Each recipe lists every place a change touches and what tells you when you missed one. A step
marked **compiler**, **checker** or **test** fails by itself if you skip it; a step marked
**silent** does not, so it is yours to remember.

## Add a request and its reply to the protocol

The history's `QueryHistoryWorkspaces` and `HistoryWorkspaces` are the worked example: follow
them through the tree with `git grep -n HistoryWorkspaces`.

1. **The tags.** Add the request to `ClientTag` and the reply to `ServerTag` in
   `lib/wire/include/telar_wire/serializers/telar_messages.hpp`, each with a value no other
   tag has, and their names to `clientTagName` and `serverTagName` in the same file.
   *compiler*: a tag without a name, or two tags with one value, do not compile.
2. **The messages.** Declare both structs and their `MessageSchema` in the module of their
   family, `lib/wire/<family>/<family>.cppm`. A codec or limit the schema names must be
   exported by `lib/wire/vocabulary/vocabulary.cppm`. *compiler*.
3. **The schema.** A new message is a new schema. In `lib/client/client.cppm` give
   `handshake::schema_id` its next value, add the schema to `handshake::Dialect` and
   `dialect_schemas`, and add a case for the request to `handshake::since`. *silent* for
   `since`: without the case the window sends the request to runtimes that do not know it.
4. **The contract.** Copy the last `src/cli/tests/contracts/api_schema_<schema>.json` to the
   new schema's name and add the two tags; add a row for the schema to `known_schemas` in
   `lib/client/tests/wire_schema_test.cpp`. *test*: `exec-runtime-offline-tests` fails for a
   schema without a published contract and `lib.client.wire_schema` for one without a row.
   Never edit the file or the row of a published schema.
5. **The runtime's table.** Add `ClientRequest<Request, Role, Lane>` to `ClientRequests` in
   `src/runtime/core/model/slot_store/slot_store.cppm`. `Role` is the role a client takes when
   this is its first request, not who may send it. *compiler*: a tag the wire names
   without an entry here does not compile.
6. **The handler.** Declare and define `Runtime::handle(std::uint64_t, const Request&)` in
   `src/runtime/core/runtime/runtime.cppm` and `.cpp`. *compiler*. A request another thread
   answers only submits itself there (`submitBackground`); the work goes in the service that
   owns the data, which for the history is `HistoryStore` and the branch for the request in
   `BackgroundService::execute` (`src/runtime/core/media_service/media_service.cpp`).
   *compiler*: a history request without a branch there does not compile.
7. **The reply's lane.** Add the reply's tag to `deliveryLane` in
   `src/runtime/transport/connection/connection.cppm`. *compiler*: a message without a lane
   does not compile.
8. **The literals.** `git grep -n '<previous schema>'` finds the tools and guides that spell
   the schema: `src/cli/tools/check_*.py`, `src/cli/exec-runtime.md`,
   `src/runtime/control-queries.md`. *test* for the tools, *silent* for the guides.
9. **A test through the owner's interface**: the store for what it answers, and a real runtime
   over its socket (`RuntimeHost` and `ProtocolPeer` in `src/runtime/core/tests/`) for what a
   client sees.

A client then sends it: the CLI with `ControlSession::exchange<Reply>(Request{})`, the window
with `session.link.ask(request)` or `sendRegistered` from a use case of `application`. The
window ignores a reply no `apply` takes (`by_tag` in `application-session.cpp`).

## Add a use case to the window

`workbench::dragDivider` is the worked example.

1. Declare it in the partition of its feature, `src/gui/application/application-<feature>.cppm`,
   in `telar::gui::application::<feature>`, and define it in `application-<feature>.cpp`. It
   takes `Session&` and borrows the fields it works on.
2. It owns the whole change: what it mutates, what it invalidates and what it retains. The Qt
   layer passes what a person did, in the window's own units, and calls nothing else.
3. A request it waits for goes out with `session.link.ask(request)`, and it records the wait
   from the id it gets back.
4. Call it from the controller in `src/gui/ui/app/`, which then refreshes what it shows.
5. Test it in `src/gui/application/tests/` with `TestSession` and a `Transport` of
   `session_fixture`: drive the use case, then check what went out on the wire and what the
   session shows.

## Move or rename a domain

```sh
tools/move-cpp-domain.py runtime http=traffic/http
python3 tools/check-cpp-modules.py
```

The tool renames the modules in every importer, the CMake target, alias and `DEPS`, the CTest
label and the paths. The checker then names what is left to decide by hand. A folder that now
holds other domains needs `EXCLUDE` in its `telar_add_domain`; `tools/move-cpp-domain.py --seal
<folder>` gives it one entry of `public_modules`, and `--fix-deps` makes every domain depend on
what it imports. A relative path in a CMake file or a script, and the name of a test program a
test spells, are not rewritten: build and run the domain's tests to find them.
