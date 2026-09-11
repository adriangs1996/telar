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

pub const utf8_bom = "\xEF\xBB\xBF";

pub const Event = @import("SseEvent.zig");

pub const Decoder = @import("Decoder.zig");

pub const max_captured_events = 4;

const CapturedEvent = @import("CapturedEvent.zig");

const Capture = @import("SseCapture.zig");

const CapturedExpectation = @import("CapturedExpectation.zig");

const CountExpectation = @import("CountExpectation.zig");

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
