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

/// Maximum number of bytes retained for one `event` field value.
pub const max_event_name_bytes = 128;

/// Maximum number of bytes retained for one logical SSE line.
pub const max_line_bytes = 4 * 1024;

/// Maximum number of bytes retained across the `data` fields of one event.
pub const max_data_bytes = 4 * 1024;

const utf8_bom = "\xEF\xBB\xBF";

/// One complete SSE event.
///
/// `name` and `data` borrow storage from the decoder. They remain valid only
/// while the callback passed to `Decoder.feed` is running. A consumer that
/// needs either value afterwards must copy it.
pub const Event = struct {
    /// Explicit `event` value, or `"message"` when no value was provided.
    name: []const u8,

    /// Values from all `data` fields, joined with one LF between fields.
    data: []const u8,

    /// Whether a line, event name, or event data exceeded its fixed bound.
    truncated: bool,
};

/// Incremental decoder for one SSE response body.
///
/// Initialize with `.{}`, call `feed` for every response-body chunk in order,
/// then call `deinit` when the response ends. A decoder owns the unfinished
/// state of one stream and must not be shared by concurrent responses.
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

    /// Whether `feed` has decided if the stream starts with a UTF-8 BOM.
    /// Once true, every later byte is ordinary SSE input.
    bom_checked: bool = false,

    /// Number of leading bytes that currently match `utf8_bom` while the
    /// stream-start decision remains incomplete.
    bom_prefix_len: usize = 0,

    /// Consumes the next contiguous bytes from one SSE response body.
    ///
    /// `input` may contain part of a line, several complete events, or nothing.
    /// The method retains incomplete state for the next call. Every blank-line
    /// terminated event with at least one `data` field invokes `sink.emit`
    /// exactly once. One call may therefore emit zero, one, or many events.
    ///
    /// `sink.emit` receives borrowed slices into this decoder. The sink must
    /// copy them if it needs to retain them. `feed` returns no value because
    /// events are its output. It must not allocate, parse JSON, or report
    /// malformed input as a transport failure. An oversized line contributes
    /// the prefix that fits, marks the current event as truncated, and discards
    /// its tail until the next line boundary.
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
    ///     count: usize = 0,
    ///
    ///     pub fn emit(sink: *Sink, event: sse.Event) void {
    ///         std.debug.assert(std.mem.eql(u8, event.name, "message_stop"));
    ///         std.debug.assert(std.mem.eql(u8, event.data, "{}"));
    ///         sink.count += 1;
    ///     }
    /// };
    ///
    /// pub fn main() void {
    ///     var decoder: sse.Decoder = .{};
    ///     defer decoder.deinit();
    ///     var sink: Sink = .{};
    ///
    ///     decoder.feed("event: message_stop\ndata: {}\n\n", &sink);
    ///     std.debug.assert(sink.count == 1);
    /// }
    /// ```
    pub fn feed(decoder: *Decoder, input: []const u8, sink: anytype) void {
        for (input) |byte| {
            if (!decoder.bom_checked) {
                if (byte == utf8_bom[decoder.bom_prefix_len]) {
                    decoder.bom_prefix_len += 1;

                    if (decoder.bom_prefix_len == utf8_bom.len) {
                        decoder.bom_checked = true;
                        decoder.bom_prefix_len = 0;
                    }

                    continue;
                }

                const prefix_len = decoder.bom_prefix_len;
                decoder.bom_checked = true;
                decoder.bom_prefix_len = 0;
                for (utf8_bom[0..prefix_len]) |prefix_byte| {
                    decoder.consumeByte(prefix_byte, sink);
                }
            }
            decoder.consumeByte(byte, sink);
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

    /// Consumes one byte after the optional stream-start BOM is resolved.
    ///
    /// This method handles CR, LF, and CRLF line endings, skips the remainder
    /// of oversized lines, and appends ordinary bytes to the current line. It
    /// may emit an event when the byte completes a blank line. It never handles
    /// BOM state; `feed` owns that stream-level decision.
    fn consumeByte(decoder: *Decoder, byte: u8, sink: anytype) void {
        const byte_is_lf = byte == '\n';
        const byte_is_cr = byte == '\r';

        if (decoder.swallow_lf) {
            decoder.swallow_lf = false;
            if (byte_is_lf) {
                return;
            }
        }

        if (decoder.discarding_line) {
            if (byte_is_lf or byte_is_cr) {
                decoder.discarding_line = false;
                decoder.resetLine();
                decoder.swallow_lf = byte_is_cr;
            }
            return;
        }

        switch (byte) {
            '\r' => {
                decoder.finishLine(sink);
                decoder.swallow_lf = true;
            },
            '\n' => decoder.finishLine(sink),
            else => decoder.pushByte(byte),
        }
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
    fn finishLine(decoder: *Decoder, sink: anytype) void {
        defer decoder.resetLine();

        if (!decoder.isLineEmpty()) {
            decoder.processLine();
            return;
        }

        if (decoder.has_data) {
            const event_name = if (decoder.isEventNameEmpty())
                "message"
            else
                decoder.getEventName();

            sink.emit(.{
                .data = decoder.getEventData(),
                .name = event_name,
                .truncated = decoder.event_truncated,
            });
        }
        decoder.resetEvent();
    }

    fn isLineEmpty(decoder: *Decoder) bool {
        return decoder.line_len == 0;
    }

    /// Appends one non-terminator byte to the current line without allocating.
    ///
    /// Once the fixed line buffer is full, this method processes the retained
    /// prefix as a truncated field, then ignores the tail until the next line
    /// terminator. The prefix is processed exactly once.
    fn pushByte(decoder: *Decoder, byte: u8) void {
        if (decoder.line_len < max_line_bytes) {
            decoder.line[decoder.line_len] = byte;
            decoder.line_len += 1;
        } else {
            decoder.event_truncated = true;
            decoder.processLine();
            decoder.resetLine();
            decoder.discarding_line = true;
        }
    }

    /// Clears pending event metadata without wiping its buffers.
    fn resetEvent(decoder: *Decoder) void {
        decoder.event_name_len = 0;
        decoder.event_data_len = 0;
        decoder.has_data = false;
        decoder.event_truncated = false;
    }

    /// Clears the current line length without wiping its buffer.
    fn resetLine(decoder: *Decoder) void {
        decoder.line_len = 0;
    }

    fn isEventNameEmpty(decoder: *Decoder) bool {
        return decoder.event_name_len == 0;
    }

    fn getEventName(decoder: *Decoder) []const u8 {
        return decoder.event_name[0..decoder.event_name_len];
    }

    fn getEventData(decoder: *Decoder) []const u8 {
        return decoder.event_data[0..decoder.event_data_len];
    }

    fn getLine(decoder: *Decoder) []const u8 {
        return decoder.line[0..decoder.line_len];
    }

    /// Interprets the buffered SSE line and updates the pending event.
    ///
    /// The buffer contains either a complete line or the retained prefix of an
    /// oversized line. It is split at its first colon. A line without a colon
    /// has an empty value. Exactly one leading ASCII space is removed from the
    /// value. Comment lines and unknown fields are ignored. An `event` field
    /// replaces the pending name. A `data` field appends its value, inserting
    /// one LF between consecutive data fields. This method never emits an event.
    fn processLine(decoder: *Decoder) void {
        const line = decoder.getLine();
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field_name = line[0..(colon orelse line.len)];
        var field_value = if (colon) |index|
            line[index + 1 ..]
        else
            "";

        if (field_value.len > 0 and field_value[0] == ' ') {
            field_value = field_value[1..];
        }

        if (std.mem.eql(u8, field_name, "event")) {
            decoder.setEventName(field_value);
        } else if (std.mem.eql(u8, field_name, "data")) {
            if (decoder.has_data) {
                decoder.appendData("\n");
            }
            decoder.appendData(field_value);
        }
    }

    /// Replaces the pending event name with a bounded copy of `event_name`.
    ///
    /// An empty value clears the name, which makes `finishLine` use `"message"`.
    /// If the value exceeds `max_event_name_bytes`, this method keeps the
    /// prefix that fits and marks the pending event as truncated.
    fn setEventName(decoder: *Decoder, event_name: []const u8) void {
        decoder.event_name_len = 0;
        const n = @min(max_event_name_bytes, event_name.len);
        if (n < event_name.len) {
            decoder.event_truncated = true;
        }

        @memcpy(decoder.event_name[0..n], event_name[0..n]);
        decoder.event_name_len = n;
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

    pub fn emit(capture: *Capture, event: Event) void {
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

const CapturedExpectation = struct {
    name: []const u8,
    data: []const u8,
    truncated: bool,
};

const CountExpectation = struct {
    count: usize,
    hint: []const u8,
};

fn expectCaptured(capture: *const Capture, index: usize, expected: CapturedExpectation) !void {
    if (index >= capture.len) {
        std.debug.print("\nMissing SSE event at index {d}. Only {d} event(s) were emitted.\n", .{ index, capture.len });
        return error.MissingSseEvent;
    }
    try std.testing.expectEqualStrings(expected.name, capture.events[index].nameSlice());
    try std.testing.expectEqualStrings(expected.data, capture.events[index].dataSlice());
    if (capture.events[index].truncated != expected.truncated) {
        std.debug.print(
            "\nSSE event {d} has the wrong truncation state. Expected {}, found {}.\n",
            .{ index, expected.truncated, capture.events[index].truncated },
        );
        return error.UnexpectedSseTruncation;
    }
}

fn expectEventCount(decoder: *const Decoder, capture: *const Capture, expected: CountExpectation) !void {
    if (capture.len == expected.count) {
        return;
    }

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
            "    swallow next LF:     {}\n" ++
            "    BOM checked:         {}\n" ++
            "    BOM prefix bytes:    {d}\n" ++
            "    truncated:           {}\n",
        .{
            expected.count,
            capture.len,
            expected.hint,
            decoder.line_len,
            decoder.event_name_len,
            decoder.event_data_len,
            decoder.has_data,
            decoder.discarding_line,
            decoder.swallow_lf,
            decoder.bom_checked,
            decoder.bom_prefix_len,
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

    decoder.feed(end_turn_event, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "A complete event ended with a blank line, so feed must call emit exactly once." });
    try expectCaptured(&capture, 0, .{ .name = "message_delta", .data = "{\"delta\":{\"stop_reason\":\"end_turn\"}}", .truncated = false });
}

test "an event is not emitted before its blank line" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(
        "event: message_stop\n" ++
            "data: {}\n",
        &capture,
    );
    try expectEventCount(&decoder, &capture, .{ .count = 0, .hint = "The event has no terminating blank line yet and must remain pending." });

    decoder.feed("\n", &capture);
    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "The second feed supplied the blank line. Pending fields must survive between feed calls." });
    try expectCaptured(&capture, 0, .{ .name = "message_stop", .data = "{}", .truncated = false });
}

test "an SSE event survives every possible two-chunk split" {
    for (0..end_turn_event.len + 1) |split| {
        var decoder: Decoder = .{};
        defer decoder.deinit();
        var capture: Capture = .{};

        decoder.feed(end_turn_event[0..split], &capture);
        decoder.feed(end_turn_event[split..], &capture);

        var hint_buffer: [192]u8 = undefined;
        const hint = try std.fmt.bufPrint(
            &hint_buffer,
            "The valid stream was split at byte {d} of {d}. Unfinished state must survive both feed calls.",
            .{ split, end_turn_event.len },
        );
        try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = hint });
        try expectCaptured(&capture, 0, .{ .name = "message_delta", .data = "{\"delta\":{\"stop_reason\":\"end_turn\"}}", .truncated = false });
    }
}

test "an SSE event survives one-byte input chunks" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    for (0..end_turn_event.len) |index|
        decoder.feed(end_turn_event[index..][0..1], &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "Every feed contained one byte. State must survive until the final blank line arrives." });
    try expectCaptured(&capture, 0, .{ .name = "message_delta", .data = "{\"delta\":{\"stop_reason\":\"end_turn\"}}", .truncated = false });
}

test "CRLF line endings do not become part of event fields" {
    const input =
        "event: message_stop\r\n" ++
        "data: {\"type\":\"message_stop\"}\r\n" ++
        "\r\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "CRLF must terminate one line, and the CR must not become part of either field." });
    try expectCaptured(&capture, 0, .{ .name = "message_stop", .data = "{\"type\":\"message_stop\"}", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "Multiple data fields still form one event and are emitted at the following blank line." });
    try expectCaptured(&capture, 0, .{ .name = "response.output_text.delta", .data = "first\nsecond", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "Comment lines begin with ':' and must not clear or emit the pending event." });
    try expectCaptured(&capture, 0, .{ .name = "message_stop", .data = "{}", .truncated = false });
}

test "an absent event field uses the SSE default name" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed("data: payload\n\n", &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "An event containing data must be emitted even when its event field is absent." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "payload", .truncated = false });
}

test "an event without data is not emitted" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed("event: message_stop\n\n", &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 0, .hint = "An event field without any data field must be discarded at the blank line." });
}

test "an oversized event is marked truncated and the next event still parses" {
    const oversized: [max_line_bytes + 1]u8 = @splat('x');
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(
        "event: oversized\n" ++
            "data: kept\n" ++
            "ignored: ",
        &capture,
    );
    decoder.feed(&oversized, &capture);
    decoder.feed("\n", &capture);
    try expectEventCount(&decoder, &capture, .{ .count = 0, .hint = "The newline terminating a discarded line must not terminate the event" });
    decoder.feed(
        "\n" ++
            "event: message_stop\n" ++
            "data: {}\n" ++
            "\n",
        &capture,
    );

    try expectEventCount(&decoder, &capture, .{ .count = 2, .hint = "After an oversized line, the decoder must emit one truncated event and resynchronize for the next valid event." });
    try expectCaptured(&capture, 0, .{ .name = "oversized", .data = "kept", .truncated = true });
    try expectCaptured(&capture, 1, .{ .name = "message_stop", .data = "{}", .truncated = false });
}

test "a data line at max_line_bytes is retained completely" {
    const field = "data: ";
    const payload_len = max_line_bytes - field.len;
    const payload: [payload_len]u8 = @splat('x');
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(field, &capture);
    decoder.feed(&payload, &capture);
    decoder.feed("\n\n", &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "A line exactly at the byte limit must be processed without truncation." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = &payload, .truncated = false });
}

test "an oversized data line retains its bounded prefix" {
    const field = "data: ";
    const retained_payload_len = max_line_bytes - field.len;
    const payload: [retained_payload_len + 1]u8 = @splat('x');
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(field, &capture);
    decoder.feed(&payload, &capture);
    decoder.feed("\n\n", &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "An oversized data field still counts as data and must dispatch a truncated event." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = payload[0..retained_payload_len], .truncated = true });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "A later event field must replace the previous event name." });
    try expectCaptured(&capture, 0, .{ .name = "second", .data = "payload", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "A discarded event must not affect the following event." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "payload", .truncated = false });
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

        decoder.feed(input[0..split], &capture);
        decoder.feed(input[split..], &capture);

        var hint_buffer: [192]u8 = undefined;
        const hint = try std.fmt.bufPrint(
            &hint_buffer,
            "The leading UTF-8 BOM or the CRLF stream was split at byte {d} of {d}.",
            .{ split, input.len },
        );
        try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = hint });
        try expectCaptured(&capture, 0, .{ .name = "named", .data = "payload", .truncated = false });
    }
}

test "a BOM-like UTF-8 prefix is replayed when it diverges" {
    const inputs = [_][]const u8{
        "\xEF\xBA\x80",
        "\xEF\xBB\x80",
    };

    for (inputs) |input| {
        for (0..input.len + 1) |split| {
            var decoder: Decoder = .{};
            defer decoder.deinit();
            var capture: Capture = .{};

            decoder.feed(input[0..split], &capture);
            decoder.feed(input[split..], &capture);

            try expectEventCount(&decoder, &capture, .{ .count = 0, .hint = "An unterminated line must remain pending while its BOM-like prefix is replayed." });
            try std.testing.expectEqualStrings(input, decoder.getLine());
        }
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "Only one BOM at the start of the stream is stripped. A second BOM becomes part of the field name." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "visible", .truncated = false });
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

        decoder.feed(input[0..split], &capture);
        decoder.feed(input[split..], &capture);

        var hint_buffer: [192]u8 = undefined;
        const hint = try std.fmt.bufPrint(
            &hint_buffer,
            "A mixed-newline SSE stream was split at byte {d} of {d}.",
            .{ split, input.len },
        );
        try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = hint });
        try expectCaptured(&capture, 0, .{ .name = "mixed", .data = "first\nsecond", .truncated = false });
    }
}

test "a CRLF pair is one line ending rather than two" {
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed("data: payload\r\n", &capture);
    try expectEventCount(&decoder, &capture, .{ .count = 0, .hint = "The LF following a CR must be swallowed instead of becoming a blank line." });

    decoder.feed("\r\n", &capture);
    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "The second CRLF is the blank line that dispatches the event." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "payload", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 2, .hint = "A colonless event field clears the name and every colonless data field contributes an empty value." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "", .truncated = false });
    try expectCaptured(&capture, 1, .{ .name = "message", .data = "\n", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "Field parsing must split once and remove one ASCII space, never a tab." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "\ttab\n spaced\nvalue:with:colons", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "Only the exact lowercase data field has protocol meaning." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "kept", .truncated = false });
}

test "valid UTF-8 bytes are preserved in event names and data" {
    const input =
        "event: r\xC3\xA9ponse\n" ++
        "data: ok\xE2\x80\xA6\n" ++
        "\n";
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 1, .hint = "SSE is UTF-8 and non-ASCII bytes must survive framing unchanged." });
    try expectCaptured(&capture, 0, .{ .name = "r\xC3\xA9ponse", .data = "ok\xE2\x80\xA6", .truncated = false });
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

    decoder.feed(input, &capture);

    try expectEventCount(&decoder, &capture, .{ .count = 2, .hint = "An empty data field still dispatches, and NUL is valid event data." });
    try expectCaptured(&capture, 0, .{ .name = "message", .data = "", .truncated = false });
    try expectCaptured(&capture, 1, .{ .name = "message", .data = "\x00\n", .truncated = false });
}

test "an oversized line resynchronizes at a lone CR" {
    const oversized: [max_line_bytes + 1]u8 = @splat('x');
    var decoder: Decoder = .{};
    defer decoder.deinit();
    var capture: Capture = .{};

    decoder.feed(
        "event: oversized\n" ++
            "data: kept\n" ++
            "ignored: ",
        &capture,
    );
    decoder.feed(&oversized, &capture);
    decoder.feed("\r", &capture);
    try expectEventCount(&decoder, &capture, .{ .count = 0, .hint = "The CR terminates only the discarded oversized line, not the pending event." });

    decoder.feed(
        "\r" ++
            "event: next\r" ++
            "data: ok\r" ++
            "\r",
        &capture,
    );

    try expectEventCount(&decoder, &capture, .{ .count = 2, .hint = "After a discarded line ends with CR, both the pending and following events must parse." });
    try expectCaptured(&capture, 0, .{ .name = "oversized", .data = "kept", .truncated = true });
    try expectCaptured(&capture, 1, .{ .name = "next", .data = "ok", .truncated = false });
}
