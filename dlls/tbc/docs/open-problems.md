# Open problems

Findings from running the checker over `runtime-cpp` and `gui-cpp` that are
not solved yet. Each entry names the sites that show it,
whether they were verified, and what would resolve it. Sites are
`services/`-relative.

## Capacity is not modeled

`runtime-cpp/proxy/http2_endpoint_connection.hpp` 374, 406, 407, 409, 442.
Verified. `Fields::add` stores `nghttp2_nv` pointers into the strings of
`names_` and then grows `names_`. The code is safe only because the constructor
reserves `maximum_fields + 4` and never adds more, which the checker cannot see:
growth always counts as reallocation. Either the checker reasons about reserved
capacity, or the code stores indices instead of pointers.

## A conditional retention gives no hint

`runtime-cpp/terminal/pty_response_queue.hpp` 163 as of `b4ec042df`, reported at
`runtime-cpp/graphics/file_input.hpp` 37, 39, 45, 65, 66, 134, 143 and
`runtime-cpp/tests/pty_response_queue_test.cpp` 57, 58, 143, 175, 189, 207, 261,
320, 322. Verified, not a memory error. `PtyResponseQueue::append` served
`tryPush`, which copies, and `tryPushOwned`, which keeps the caller's view next
to its owner, with one store: `views_[index] = owned_[index] ? response : ...`.
The checker counts a retention on one path as a retention on every call. That is
intended: a function that may keep its argument, depending on a value its caller
does not see, is as opaque to a reader as to the checker. Splitting `append`
into a copying function and an owning one resolves all 16 sites. After the
split the copying path is checked: making it keep the reply brings back the same
16 diagnostics, then real uses after free across threads. `flow.conditional_retention`
and `flow.split_retention_copied` reduce the case.

What is missing is a hint toward that split. The diagnostic names the storage
that dies and the later use:

```text
pty_response_queue_test.cpp:57:5: warning: operation invalidates a borrow used later [tbc-invalidated-borrow]
pty_response_queue_test.cpp:52:42: note: borrowed storage originates here
pty_response_queue_test.cpp:54:15: note: invalidated borrow is used here
```

Nothing points at the store in `append` or says that it keeps the borrow on
some paths only. A function summary records what the function retains, not
where, so the store is lost once the summary is built. Two additions would lead
to the split:

- A note at the store that keeps the borrow, reached through the caller's call:
  `pty_response_queue.hpp:163:5: note: 'views_' keeps the borrow on some paths
  only, through the call at pty_response_queue_test.cpp:54`. The store must not
  count in a borrow's identity, as `borrow_site` does not, or one borrow kept at
  two stores becomes two and loan sets grow.
- Whether the store keeps it on every path or only some: a second analysis that
  intersects at joins what the current one unites. Its cost is not measured.

The corpus cannot assert either yet: notes are permitted but not compared.

## A shared owner beside a view

`runtime-cpp/terminal/control/reply.hpp` 90. `Reply::publish` passes
`owned_->bytes` with `owned_` to `tryPushOwned`, and the queue keeps a copy of
that shared owner until it consumes the reply. The checker does not relate the
owner to the view: when the caller's owner dies before the queue is read, it
reports the view as invalidated (`flow.shared_owner_alive`, pending). The last
survey reports nothing in `reply.hpp`. An owner unrelated to the view's bytes is
rejected, as it should be (`flow.unrelated_owner`).

## Pointers held in fields

A borrow follows what an input designates through the input itself and through
reference fields. Past a pointer held in a field, such as `FlowStream::gate_` or
`ApplicationRelay::flow_`, what the pointer designates stays merged with the
object that holds it. Following those too made `proxy_service_test.cpp` and
`traffic_flow_test.cpp` exceed two and a half minutes, against 8 and 6 seconds
without: `FlowGate` keeps views of many relay buffers, and every read through
the merged holder multiplied them. Writes and invalidations through an input
already discard designations whose place has the wrong type; that alone does
not bound it, and reads would need the same filter.

## Retention inside proxy connections

`runtime-cpp/http1/intercepted_relay.hpp` 122, 127, 273 and
`runtime-cpp/proxy/http1_connection.hpp` 31, 35, 54, 62, 75. Verified, not a
memory error. `FlowGate::write` keeps the caller's bytes in `event_.bytes` after
it returns; later calls either replace them before reading or copy the event and
clear the bytes in `fail`. `FlowStream` reaches the gate through `gate_`, a
pointer held in a field, so the gate's contents merge with the stream's and a
later write through the stream counts as using the stale bytes. With the event
copied into a local before `intercept` and `observeFlow`, all 8 sites disappear.

`runtime-cpp/proxy/service.hpp` 127, 137, 180, 227 and
`runtime-cpp/memory/slot_indexes.hpp` 40. Verified, not a memory error. Each
connection in `ProxyService::slots_` holds views of its own heap objects, such as
`FlowState::event_` viewing `client_`. Replacing a connection's `FlowState`
invalidates those views in every slot, because the slots are one place. A view
held inside the storage it points into dies with that storage, so it should not
be reported; the checker would need where the holder lies, not only where the
view points.

`Http1MessageRelay::write_data_` keeps a pointer from `peekView()` across calls.
Verified safe: `StreamReadBuffer` refills only once empty, the relay consumes
only after writing, and `TlsTunnel` destroys its relay before its session.

`runtime-cpp/proxy/http2_endpoint_connection.hpp` 238 is not triaged.

The runtime tree grew from 189 to 275 diagnostics with in-progress changes. Of
its memory diagnostics, the ones not listed in this file are not triaged.

## History browser positions

`gui-cpp/tests/session_test.cpp` 713. Not verified. A view of
`HistoryBrowser::query_` is held at an unknown position inside
`Session::history_`, so it outlives the field writes that replace it.

## Functions defined in another translation unit

`gui-cpp`: 27 `tbc-missing-contract` sites for `ConfigurationSource::input`,
`ConfigurationSource::configuration`, and `Application::configuration`. Each is
declared in a header and defined in another source file, and its result is used,
for instance by calling a member function on the returned reference. Declaring
them as `tbc::view<const InputConfiguration &> input() const noexcept;` and so on
resolves the calls, and the checker verifies that contract when it checks the
defining source file. That needs the services to include `tbc/view.hpp`, which
none does yet. Cross-translation-unit summaries would infer these instead.

## In-progress `dlls/ebnf` edits

`lifetime-check` reports a contract violation at `dlls/ebnf/parser.hpp:166`
after `parsing_ring_buffer` became `std::array<token, N>`. The checker from
before field paths reports it too. `lifetime-check-tests` does not compile
while `tests/lexer_test.cpp` ignores `nodiscard` results.
