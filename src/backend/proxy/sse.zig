//! Incremental, bounded framing for Server-Sent Events.
//!
//! This decoder has one job. It turns arbitrary response-body chunks into SSE
//! events. It does not parse JSON and it does not decide whether an agent is
//! working or ready.
//!
//! The later data path will be:
//!
//! ```text
//! HTTP response bytes
//!     -> Decoder.feed
//!     -> Event { name, data, truncated }
//!     -> provider-specific interpretation
//!     -> agent lifecycle evidence
//! ```
//!
//! Network reads may split the stream between any two bytes. The decoder keeps
//! an unfinished line and event across `feed` calls. All storage is fixed-size
//! so observing a response cannot allocate or grow without a bound.

const std = @import("std");

pub const max_event_name_bytes = 128;
pub const max_line_bytes = 4 * 1024;
pub const max_data_bytes = 4 * 1024;

/// One complete SSE event.
///
/// `name` and `data` borrow storage from the decoder. They remain valid only
/// while the callback passed to `Decoder.feed` is running. A consumer that
/// needs either value afterwards must copy it.
pub const Event = struct {
    name: []const u8,
    data: []const u8,
    truncated: bool,
};

pub const Decoder = struct {
    /// The current logical line without its CR, LF, or CRLF terminator.
    /// `feed` consumes terminators instead of storing them here.
    line: [max_line_bytes]u8 = undefined,
    line_len: usize = 0,

    /// Whether `feed` is ignoring the rest of a line that exceeded
    /// `max_line_bytes`.
    discarding_line: bool = false,

    /// Fields accumulated for the event that has not reached its blank line.
    event_name: [max_event_name_bytes]u8 = undefined,
    event_name_len: usize = 0,
    event_data: [max_data_bytes]u8 = undefined,
    event_data_len: usize = 0,
    has_data: bool = false,
    event_truncated: bool = false,

    /// Whether the previous byte was CR. The next LF, if present, belongs to
    /// the same CRLF terminator and must not create another empty line.
    swallow_lf: bool = false,

    /// Consumes the next contiguous bytes from one SSE response body.
    ///
    /// `input` may contain part of a line, several complete events, or nothing.
    /// The method retains incomplete state for the next call. Every blank-line
    /// terminated event with at least one `data:` field invokes `emit` exactly
    /// once. One call may therefore invoke `emit` zero, one, or many times.
    ///
    /// The callback receives borrowed slices into this decoder. It must copy
    /// them if it needs to retain them. `feed` returns no value because events
    /// are its output. It must not allocate, parse JSON, or report malformed
    /// input as a transport failure. Oversized input marks the current event as
    /// truncated and the decoder resumes at the next line boundary.
    ///
    /// At the start of the stream, this method must ignore one leading UTF-8
    /// BOM when present, including when its three bytes arrive in separate
    /// calls. A later BOM is ordinary input.
    ///
    /// Example:
    ///
    /// ```zig
    /// const std = @import("std");
    /// const sse = @import("sse.zig");
    ///
    /// const Sink = struct {
    ///     fn emit(count: *usize, event: sse.Event) void {
    ///         std.debug.assert(std.mem.eql(u8, event.name, "message_stop"));
    ///         std.debug.assert(std.mem.eql(u8, event.data, "{}"));
    ///         count.* += 1;
    ///     }
    /// };
    ///
    /// pub fn main() void {
    ///     var decoder: sse.Decoder = .{};
    ///     defer decoder.deinit();
    ///     var count: usize = 0;
    ///
    ///     decoder.feed("event: message_stop\ndata: {}\n\n", &count, Sink.emit);
    ///     std.debug.assert(count == 1);
    /// }
    /// ```
    pub fn feed(decoder: *Decoder, input: []const u8, context: anytype, comptime emit: fn (@TypeOf(context), Event) void) void {
        for (input) |byte| {
            const byteIsLF = byte == '\n';
            const byteIsCR = byte == '\r';

            if (decoder.swallow_lf) {
                decoder.swallow_lf = false;
                if (byteIsLF) {
                    continue;
                }
            }

            if (decoder.discarding_line) {
                if (byteIsLF or byteIsCR) {
                    decoder.discarding_line = false;
                    decoder.resetLine();
                    decoder.swallow_lf = byteIsCR;
                }
                continue;
            }

            switch (byte) {
                '\r' => {
                    decoder.finishLine(context, emit);
                    decoder.swallow_lf = true;
                },
                '\n' => decoder.finishLine(context, emit),
                else => decoder.pushByte(byte),
            }
        }
    }

    /// Erases every buffered response byte and invalidates the decoder.
    ///
    /// This method emits nothing and returns nothing. Call it when the HTTP
    /// response, HTTP/2 stream, or owning connection is destroyed. The secure
    /// wipe matters because SSE data may contain model output or secrets.
    /// Assign `.{}` to the decoder before using it again.
    ///
    /// Example:
    ///
    /// ```zig
    /// const sse = @import("sse.zig");
    ///
    /// pub fn main() void {
    ///     var decoder: sse.Decoder = .{};
    ///     defer decoder.deinit();
    /// }
    /// ```
    pub fn deinit(decoder: *Decoder) void {
        std.crypto.secureZero(u8, std.mem.asBytes(decoder));
    }

    /// Processes the logical line whose terminator `feed` just consumed.
    ///
    /// A non-empty line updates the pending event through `processLine`. An
    /// empty line emits that event when it contains at least one `data` field,
    /// then clears the event even when nothing was emitted. The callback must
    /// finish using its borrowed slices before this method resets the buffers.
    /// The line buffer is cleared on every return path.
    ///
    /// `feed` must not call this method for a discarded oversized line because
    /// that line has no valid field to process.
    fn finishLine(decoder: *Decoder, context: anytype, comptime emit: fn (@TypeOf(context), Event) void) void {
        defer decoder.resetLine();

        if (!decoder.hasEmptyLine()) {
            decoder.processLine();
            return;
        }

        if (decoder.has_data) {
            const event_name = if (decoder.isEventNameEmpty())
                "message"
            else
                decoder.getEventName();

            emit(
                context,
                Event{
                    .data = decoder.getEventData(),
                    .name = event_name,
                    .truncated = decoder.event_truncated,
                },
            );
        }
        decoder.resetEvent();
    }

    /// Returns whether the current logical line contains no bytes.
    ///
    /// Only `finishLine` uses this distinction. An empty line ends the pending
    /// event, while a non-empty line contributes a field to it.
    fn hasEmptyLine(decoder: *Decoder) bool {
        return decoder.line_len == 0;
    }

    /// Appends one non-terminator byte to the current line without allocating.
    ///
    /// Once the fixed line buffer is full, this method preserves memory safety
    /// by entering discard mode instead of writing past the buffer. It also
    /// marks the pending event as truncated. `feed` then ignores bytes until
    /// the next line terminator.
    fn pushByte(decoder: *Decoder, byte: u8) void {
        if (decoder.line_len < max_line_bytes) {
            decoder.line[decoder.line_len] = byte;
            decoder.line_len += 1;
        } else {
            decoder.discarding_line = true;
            decoder.event_truncated = true;
        }
    }

    /// Logically discards every field accumulated for the pending event.
    ///
    /// This resets lengths and flags but does not wipe the backing arrays.
    /// `deinit` performs the secure wipe when the decoder is destroyed. Any
    /// slices previously returned by `getEventName` or `getEventData` become
    /// invalid after this call.
    fn resetEvent(decoder: *Decoder) void {
        decoder.event_data = undefined;
        decoder.event_name = undefined;
        decoder.event_name_len = 0;
        decoder.event_data_len = 0;
        decoder.has_data = false;
        decoder.event_truncated = false;
    }

    /// Logically discards the current line so the next byte starts a new one.
    ///
    /// This resets `line_len` but does not wipe the backing array. A slice
    /// previously returned by `fieldValue` becomes invalid after this call.
    fn resetLine(decoder: *Decoder) void {
        decoder.line = undefined;
        decoder.line_len = 0;
    }

    /// Returns whether the pending event has no explicit event name.
    ///
    /// `finishLine` uses this result to select the SSE default name,
    /// `"message"`, when dispatching an event.
    fn isEventNameEmpty(decoder: *Decoder) bool {
        return decoder.event_name_len == 0;
    }

    /// Returns the initialized portion of the pending event-name buffer.
    ///
    /// The returned slice borrows decoder storage. It remains valid only until
    /// the decoder replaces or resets the pending event.
    fn getEventName(decoder: *Decoder) []const u8 {
        return decoder.event_name[0..decoder.event_name_len];
    }

    /// Returns the initialized portion of the pending event-data buffer.
    ///
    /// The returned slice borrows decoder storage. It remains valid only until
    /// the decoder appends more data or resets the pending event.
    fn getEventData(decoder: *Decoder) []const u8 {
        return decoder.event_data[0..decoder.event_data_len];
    }

    /// Interprets one complete, non-empty SSE line and updates the pending event.
    ///
    /// The line is split at its first colon. A line without a colon has an
    /// empty value. Exactly one leading ASCII space is removed from the value.
    /// Comment lines and unknown fields are ignored. An `event` field replaces
    /// the pending name. A `data` field appends its value, inserting one LF
    /// between consecutive data fields. This method never emits an event.
    fn processLine(decoder: *Decoder) void {
        if (decoder.line_len > 0 and decoder.line[0] == ':') {
            return;
        }

        if (decoder.hasPrefix("event:")) {
            const value = decoder.fieldValue("event:");
            decoder.setEventName(value);
        }

        if (decoder.hasPrefix("data:")) {
            const value = decoder.fieldValue("data:");
            if (decoder.has_data) {
                decoder.appendData("\n");
            }
            decoder.appendData(value);
        }
    }

    /// Returns the value after a field prefix that includes its colon.
    ///
    /// The caller must first prove that the current line starts with `field`.
    /// The returned slice excludes at most one leading ASCII space and borrows
    /// storage from the current line buffer.
    fn fieldValue(decoder: *Decoder, comptime field: []const u8) []const u8 {
        var rest = decoder.line[field.len..decoder.line_len];
        if (rest.len > 0 and rest[0] == ' ') rest = rest[1..]; // spec: a single space
        return rest;
    }

    /// Returns whether the current line starts with the exact byte sequence.
    ///
    /// Comparison is case-sensitive, as required for SSE field names. This
    /// method does not give `prefix` any field-boundary semantics.
    fn hasPrefix(decoder: *Decoder, prefix: []const u8) bool {
        if (decoder.line_len <= 0) return false;

        return std.mem.startsWith(u8, decoder.line[0..decoder.line_len], prefix);
    }

    /// Replaces the pending event name with a bounded copy of `event_name`.
    ///
    /// An empty value clears the name, which makes `finishLine` use `"message"`.
    /// If the value exceeds `max_event_name_bytes`, this method keeps the
    /// prefix that fits and marks the pending event as truncated.
    fn setEventName(decoder: *Decoder, event_name: []const u8) void {
        if (decoder.event_name_len > 0) {
            // We have received two event: directives
            // Overwrite with the latest one
            decoder.event_name_len = 0;
        }
        const n = @min(max_event_name_bytes, event_name.len);
        if (n < event_name.len) {
            decoder.event_truncated = true;
        }

        @memcpy(decoder.event_name[decoder.event_name_len..][0..n], event_name[0..n]);
        decoder.event_name_len += n;
    }

    /// Appends bytes to the bounded event-data buffer.
    ///
    /// Calling this method records the presence of a `data` field even when
    /// `bytes` is empty. If the value does not fit, the method copies the
    /// prefix that fits and marks the pending event as truncated. It does not
    /// add separators. `processLine` inserts the LF between data fields.
    fn appendData(decoder: *Decoder, bytes: []const u8) void {
        const room = max_data_bytes - decoder.event_data_len;
        const n = @min(room, bytes.len);
        if (n < bytes.len) {
            decoder.event_truncated = true;
        }

        @memcpy(decoder.event_data[decoder.event_data_len..][0..n], bytes[0..n]);
        decoder.event_data_len += n;
        decoder.has_data = true;
    }
};

const max_captured_events = 4;

const CapturedEvent = struct {
    name: [max_event_name_bytes]u8 = undefined,
    name_len: usize = 0,
    data: [max_data_bytes]u8 = undefined,
    data_len: usize = 0,
    truncated: bool = false,

    fn nameSlice(event: *const CapturedEvent) []const u8 {
        return event.name[0..event.name_len];
    }

    fn dataSlice(event: *const CapturedEvent) []const u8 {
        return event.data[0..event.data_len];
    }
};

const Capture = struct {
    events: [max_captured_events]CapturedEvent = @splat(.{}),
    len: usize = 0,

    fn emit(capture: *Capture, event: Event) void {
        std.debug.assert(capture.len < capture.events.len);
        std.debug.assert(event.name.len <= max_event_name_bytes);
        std.debug.assert(event.data.len <= max_data_bytes);

        const destination = &capture.events[capture.len];
        @memcpy(destination.name[0..event.name.len], event.name);
        destination.name_len = event.name.len;
        @memcpy(destination.data[0..event.data.len], event.data);
        destination.data_len = event.data.len;
        destination.truncated = event.truncated;
        capture.len += 1;
    }
};

fn expectCaptured(capture: *const Capture, index: usize, expected_name: []const u8, expected_data: []const u8, expected_truncated: bool) !void {
    if (index >= capture.len) {
        std.debug.print("\nMissing SSE event at index {d}. Only {d} event(s) were emitted.\n", .{ index, capture.len });
        return error.MissingSseEvent;
    }
    try std.testing.expectEqualStrings(expected_name, capture.events[index].nameSlice());
    try std.testing.expectEqualStrings(expected_data, capture.events[index].dataSlice());
    if (capture.events[index].truncated != expected_truncated) {
        std.debug.print(
            "\nSSE event {d} has the wrong truncation state. Expected {}, found {}.\n",
            .{ index, expected_truncated, capture.events[index].truncated },
        );
        return error.UnexpectedSseTruncation;
    }
}

fn expectEventCount(decoder: *const Decoder, capture: *const Capture, expected: usize, hint: []const u8) !void {
    if (capture.len == expected) return;

    std.debug.print(
        "\nSSE event count mismatch\n" ++
            "  expected events: {d}\n" ++
            "  emitted events:  {d}\n" ++
            "  hint: {s}\n" ++
            "  decoder state after feed:\n" ++
            "    pending line bytes: {d}\n" ++
            "    pending name bytes: {d}\n" ++
            "    pending data bytes: {d}\n" ++
            "    has data:           {}\n" ++
            "    discarding line:    {}\n" ++
            "    truncated:          {}\n",
        .{
            expected,
            capture.len,
            hint,
            decoder.line_len,
            decoder.event_name_len,
            decoder.event_data_len,
            decoder.has_data,
            decoder.discarding_line,
            decoder.event_truncated,
        },
    );
    for (capture.events[0..capture.len], 0..) |event, index| {
        std.debug.print(
            "  emitted event {d}: name=\"{s}\", data_bytes={d}, truncated={}\n",
            .{ index, event.nameSlice(), event.data_len, event.truncated },
        );
    }
    return error.UnexpectedSseEventCount;
}

const end_turn_event =
    "event: message_delta\n" ++
    "data: {\"delta\":{\"stop_reason\":\"end_turn\"}}\n" ++
    "\n";

test "a complete SSE event is emitted at its blank line" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(end_turn_event, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "A complete event ended with a blank line, so feed must call emit exactly once.",
    );
    try expectCaptured(
        &capture,
        0,
        "message_delta",
        "{\"delta\":{\"stop_reason\":\"end_turn\"}}",
        false,
    );
}

test "an event is not emitted before its blank line" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(
        "event: message_stop\n" ++
            "data: {}\n",
        &capture,
        Capture.emit,
    );
    try expectEventCount(
        &decoder,
        &capture,
        0,
        "The event has no terminating blank line yet and must remain pending.",
    );

    decoder.feed("\n", &capture, Capture.emit);
    try expectEventCount(
        &decoder,
        &capture,
        1,
        "The second feed supplied the blank line. Pending fields must survive between feed calls.",
    );
    try expectCaptured(&capture, 0, "message_stop", "{}", false);
}

test "an SSE event survives every possible two-chunk split" {
    for (0..end_turn_event.len + 1) |split| {
        var decoder: Decoder = .{};
        defer decoder.deinit();
        var capture: Capture = .{};

        decoder.feed(end_turn_event[0..split], &capture, Capture.emit);
        decoder.feed(end_turn_event[split..], &capture, Capture.emit);

        var hint_buffer: [192]u8 = undefined;
        const hint = try std.fmt.bufPrint(
            &hint_buffer,
            "The valid stream was split at byte {d} of {d}. Unfinished state must survive both feed calls.",
            .{ split, end_turn_event.len },
        );
        try expectEventCount(&decoder, &capture, 1, hint);
        try expectCaptured(
            &capture,
            0,
            "message_delta",
            "{\"delta\":{\"stop_reason\":\"end_turn\"}}",
            false,
        );
    }
}

test "an SSE event survives one-byte input chunks" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    for (0..end_turn_event.len) |index|
        decoder.feed(end_turn_event[index..][0..1], &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "Every feed contained one byte. State must survive until the final blank line arrives.",
    );
    try expectCaptured(
        &capture,
        0,
        "message_delta",
        "{\"delta\":{\"stop_reason\":\"end_turn\"}}",
        false,
    );
}

test "CRLF line endings do not become part of event fields" {
    const input =
        "event: message_stop\r\n" ++
        "data: {\"type\":\"message_stop\"}\r\n" ++
        "\r\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "CRLF must terminate one line, and the CR must not become part of either field.",
    );
    try expectCaptured(
        &capture,
        0,
        "message_stop",
        "{\"type\":\"message_stop\"}",
        false,
    );
}

test "multiple data fields are joined with one LF" {
    const input =
        "event: response.output_text.delta\n" ++
        "data: first\n" ++
        "data: second\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "Multiple data fields still form one event and are emitted at the following blank line.",
    );
    try expectCaptured(
        &capture,
        0,
        "response.output_text.delta",
        "first\nsecond",
        false,
    );
}

test "comment lines do not alter the event" {
    const input =
        ": keep-alive\n" ++
        "event: message_stop\n" ++
        ": ignored between fields\n" ++
        "data: {}\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "Comment lines begin with ':' and must not clear or emit the pending event.",
    );
    try expectCaptured(&capture, 0, "message_stop", "{}", false);
}

test "an absent event field uses the SSE default name" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed("data: payload\n\n", &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "An event containing data must be emitted even when its event field is absent.",
    );
    try expectCaptured(&capture, 0, "message", "payload", false);
}

test "an event without data is not emitted" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed("event: message_stop\n\n", &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        0,
        "An event field without any data field must be discarded at the blank line.",
    );
}

test "an oversized event is marked truncated and the next event still parses" {
    var oversized: [max_line_bytes + 1]u8 = @splat('x');
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(
        "event: oversized\n" ++
            "data: kept\n" ++
            "data: ",
        &capture,
        Capture.emit,
    );
    decoder.feed(&oversized, &capture, Capture.emit);
    decoder.feed("\n", &capture, Capture.emit);
    try expectEventCount(&decoder, &capture, 0, "The newline terminating a discarded line must not terminate the event");
    decoder.feed(
        "\n" ++
            "event: message_stop\n" ++
            "data: {}\n" ++
            "\n",
        &capture,
        Capture.emit,
    );

    try expectEventCount(
        &decoder,
        &capture,
        2,
        "After an oversized line, the decoder must emit one truncated event and resynchronize for the next valid event.",
    );
    try expectCaptured(&capture, 0, "oversized", "kept", true);
    try expectCaptured(&capture, 1, "message_stop", "{}", false);
}

test "a later event field replaces previous event name" {
    const input =
        "event: first\n" ++
        "event: second\n" ++
        "data: payload\n" ++
        "\n";

    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(&decoder, &capture, 1, "A later event field must replace the previous event name.");
    try expectCaptured(&capture, 0, "second", "payload", false);
}

test "an event without data does not leak its name into the next event" {
    const input =
        "event: stale\n" ++
        "\n" ++
        "data: payload\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "A discarded event must not affect the following event.",
    );
    try expectCaptured(&capture, 0, "message", "payload", false);
}

// These cases project the WHATWG EventSource parsing algorithm onto Telar's
// bounded `Event { name, data, truncated }` contract. They mirror the wire
// cases covered by Web Platform Tests under `eventsource/format-*.any.js`.
test "one leading UTF-8 BOM is ignored across every two-chunk split" {
    const input =
        "\xEF\xBB\xBF" ++
        "event: named\r\n" ++
        "data: payload\r\n" ++
        "\r\n";

    for (0..input.len + 1) |split| {
        var decoder: Decoder = .{};
        defer decoder.deinit();
        var capture: Capture = .{};

        decoder.feed(input[0..split], &capture, Capture.emit);
        decoder.feed(input[split..], &capture, Capture.emit);

        var hint_buffer: [192]u8 = undefined;
        const hint = try std.fmt.bufPrint(
            &hint_buffer,
            "The leading UTF-8 BOM or the CRLF stream was split at byte {d} of {d}.",
            .{ split, input.len },
        );
        try expectEventCount(&decoder, &capture, 1, hint);
        try expectCaptured(&capture, 0, "named", "payload", false);
    }
}

test "only the first UTF-8 BOM is ignored" {
    const input =
        "\xEF\xBB\xBF" ++
        "\xEF\xBB\xBF" ++
        "data: hidden\n" ++
        "\n" ++
        "data: visible\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        1,
        "Only one BOM at the start of the stream is stripped. A second BOM becomes part of the field name.",
    );
    try expectCaptured(&capture, 0, "message", "visible", false);
}

test "LF CRLF and lone CR line endings survive every two-chunk split" {
    const input =
        "event: mixed\r\n" ++
        "data: first\r" ++
        "data: second\n" ++
        "\r";

    for (0..input.len + 1) |split| {
        var decoder: Decoder = .{};
        defer decoder.deinit();
        var capture: Capture = .{};

        decoder.feed(input[0..split], &capture, Capture.emit);
        decoder.feed(input[split..], &capture, Capture.emit);

        var hint_buffer: [192]u8 = undefined;
        const hint = try std.fmt.bufPrint(
            &hint_buffer,
            "A mixed-newline SSE stream was split at byte {d} of {d}.",
            .{ split, input.len },
        );
        try expectEventCount(&decoder, &capture, 1, hint);
        try expectCaptured(&capture, 0, "mixed", "first\nsecond", false);
    }
}

test "a CRLF pair is one line ending rather than two" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed("data: payload\r\n", &capture, Capture.emit);
    try expectEventCount(
        &decoder,
        &capture,
        0,
        "The LF following a CR must be swallowed instead of becoming a blank line.",
    );

    decoder.feed("\r\n", &capture, Capture.emit);
    try expectEventCount(&decoder, &capture, 1, "The second CRLF is the blank line that dispatches the event.");
    try expectCaptured(&capture, 0, "message", "payload", false);
}

test "fields without a colon have an empty value" {
    const input =
        "event: stale\n" ++
        "event\n" ++
        "data\n" ++
        "\n" ++
        "data\n" ++
        "data\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(
        &decoder,
        &capture,
        2,
        "A colonless event field clears the name and every colonless data field contributes an empty value.",
    );
    try expectCaptured(&capture, 0, "message", "", false);
    try expectCaptured(&capture, 1, "message", "\n", false);
}

test "field parsing uses the first colon and removes exactly one leading space" {
    const input =
        "data:\ttab\n" ++
        "data:  spaced\n" ++
        "data:value:with:colons\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(&decoder, &capture, 1, "Field parsing must split once and remove one ASCII space, never a tab.");
    try expectCaptured(&capture, 0, "message", "\ttab\n spaced\nvalue:with:colons", false);
}

test "field names are case-sensitive and unknown fields are ignored" {
    const input =
        "Data: uppercase\n" ++
        " data: prefixed\n" ++
        "unknown: value\n" ++
        "justsometext\n" ++
        "data: kept\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(&decoder, &capture, 1, "Only the exact lowercase data field has protocol meaning.");
    try expectCaptured(&capture, 0, "message", "kept", false);
}

test "valid UTF-8 bytes are preserved in event names and data" {
    const input =
        "event: r\xC3\xA9ponse\n" ++
        "data: ok\xE2\x80\xA6\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(&decoder, &capture, 1, "SSE is UTF-8 and non-ASCII bytes must survive framing unchanged.");
    try expectCaptured(&capture, 0, "r\xC3\xA9ponse", "ok\xE2\x80\xA6", false);
}

test "empty data fields and NUL bytes are preserved" {
    const input =
        "data:\n" ++
        "\n" ++
        "data: \x00\n" ++
        "data:\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture, Capture.emit);

    try expectEventCount(&decoder, &capture, 2, "An empty data field still dispatches, and NUL is valid event data.");
    try expectCaptured(&capture, 0, "message", "", false);
    try expectCaptured(&capture, 1, "message", "\x00\n", false);
}

test "an oversized line resynchronizes at a lone CR" {
    var oversized: [max_line_bytes + 1]u8 = @splat('x');
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(
        "event: oversized\n" ++
            "data: kept\n" ++
            "data: ",
        &capture,
        Capture.emit,
    );
    decoder.feed(&oversized, &capture, Capture.emit);
    decoder.feed("\r", &capture, Capture.emit);
    try expectEventCount(
        &decoder,
        &capture,
        0,
        "The CR terminates only the discarded oversized line, not the pending event.",
    );

    decoder.feed(
        "\r" ++
            "event: next\r" ++
            "data: ok\r" ++
            "\r",
        &capture,
        Capture.emit,
    );

    try expectEventCount(
        &decoder,
        &capture,
        2,
        "After a discarded line ends with CR, both the pending and following events must parse.",
    );
    try expectCaptured(&capture, 0, "oversized", "kept", true);
    try expectCaptured(&capture, 1, "next", "ok", false);
}
