const Summary = @This();

/// The full head, borrowed from the caller's scratch buffer and therefore
/// only valid until the next `relay` call that reuses it.
head: []const u8,
/// First line, verbatim: "POST /v1/messages HTTP/1.1" or "HTTP/1.1 200 OK".
start_line: []const u8,
body_bytes: usize,
/// Body text, truncated to the caller's budget. Auth headers never reach
/// here — see `redactedHead`.
body: []const u8,
truncated: bool,
