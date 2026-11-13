# Code style

`.clang-format` at the repository root owns indentation, braces, spacing and pointer placement. Run it on every file you touch. This document covers the layout decisions it leaves to the author, because `ColumnLimit` is 0 and clang-format keeps the line breaks it is given.

## Long calls and signatures

When a call, a signature or a template argument list reads better split, break right after the opening parenthesis. clang-format then puts one item per line and the closing parenthesis on its own line:

```cpp
inline void packet(
    std::uint32_t link_type,
    const pcap_pkthdr& header,
    const u_char* bytes,
    std::string_view interface,
    std::uint32_t index
) {
```

A break anywhere else (after the first argument, in the middle of the list) is joined back into one line, so the first break is the one that counts.

## Braced lists

A multi-line braced list ends with a trailing comma. The comma is what makes clang-format put one element per line and the closing brace on its own line:

```cpp
emit(Event{
    .kind = kind,
    .interface_index = index,
    .bytes = {data, size},
});
```

A list without the trailing comma stays on one line. Enums get their trailing comma from clang-format.

## Logical blocks

Separate logical blocks inside a function body with one blank line. A logical block is a run of statements that does one thing a reader could name: a guard, reading inputs, a computation, a write, emitting the result.

- A statement that ends on its own closing brace (a loop, an `if`, a `switch`, a multi-line lambda or braced list) closes a block: the next statement follows a blank line. `else`, `catch` and the `while` of a `do` belong to the same statement and stay attached.
- A guard clause and its early return form a block of their own.
- A run of declarations is a block of its own: the statements that operate on those variables start after a blank line. This holds even when the initializer itself does work. The exception is an `if` that checks the variable just declared: it stays attached to the declaration, and both form one block.

  ```cpp
  const auto count = ::send(socket, bytes.data(), bytes.size(), 0);
  if (count < 0) {
  ```
- A trace or instrumentation line at the top of a function (`TELAR_TRACE(...)`) belongs to the first block.
- A comment describing a block goes on the line right above its first statement.
- A function short enough to be a single block has no blank lines.
- Blocks start right after the opening brace and end right before the closing one; clang-format removes blank lines in those two places.

```cpp
inline void statistics() {
  for (auto& device : devices_) {
    if (device) {
      sample(kernel_drops_, *device);
    }
  }

  emit(Event{.kind = Kind::statistics});

  auto byIndex = [&](const Device& left, const Device& right) {
    return left.index < right.index;
  };

  std::ranges::sort(devices_, byIndex);
}
```

```cpp
inline void persist(const ReportAgentCommand& request, const RequestContext& context) {
  TELAR_TRACE("history.persistAgentCommand");
  if (request.phase == AgentCommandPhase::started && request.tool_call_id.empty()) {
    return;
  }

  // Commands outside a known session are attributed to the pane's latest one.
  const auto session = resolveSession(request, context);

  session_.bind(1, session);
  session_.next();

  Transaction transaction(database_);

  insert_.bind(1, request.tool_call_id);
  insert_.bind(2, request.command);
  insert_.finish();
  transaction.commit();
}
```

The same applies between groups of related members in a class and between groups of related declarations in an interface.
