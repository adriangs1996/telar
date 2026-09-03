const std = @import("std");
const vt = @import("ghostty-vt");

// OSC scanner for shell semantic markers.
//
// Framing is ours; parsing is libghostty-vt's. That split is not a compromise,
// it is what the library offers: `vt.osc.Parser` consumes the *payload* of an
// OSC sequence and knows nothing about `ESC ]` or its terminators, so finding
// sequence boundaries in a chunked stream stays here.
//
// The tests below are unchanged from the hand-rolled implementation this
// replaced. They are the parity gate: same input, same markers, new engine.

/// A marker recovered from the stream.
pub const Marker = union(enum) {
    /// OSC 133;A or 133;P — the shell is about to draw a prompt.
    prompt_start,
    /// OSC 133;B — the prompt is drawn; what follows is what the user types.
    command_start,
    /// OSC 133;C — the command is about to run.
    output_start,
    /// OSC 133;D;<code> — the command finished. Null when the shell published
    /// no usable status.
    command_end: ?u8,
    /// OSC 0 or OSC 2 — the window title. Shells set it to the running command
    /// from their preexec hook, which is where the command text comes from.
    ///
    /// Borrowed from the parser, which owns it until its next call. Copy it if
    /// it has to outlive that.
    title: []const u8,
};

pub const Scanner = struct {
    state: State = .ground,
    parser: vt.osc.Parser,
    pending: []const u8 = &.{},

    const State = enum { ground, escape, osc, osc_escape };

    /// The parser allocates for payloads that outgrow its inline buffer, so it
    /// wants a real allocator. Passing null makes it drop those instead.
    pub fn init(alloc: ?std.mem.Allocator) Scanner {
        return .{ .parser = .init(alloc) };
    }

    pub fn deinit(s: *Scanner) void {
        s.parser.deinit();
    }

    /// Hands a chunk to the scanner. Drain it with `next` before feeding again.
    pub fn feed(s: *Scanner, bytes: []const u8) void {
        s.pending = bytes;
    }

    /// How much of the chunk passed to `feed` has been consumed. Lets a caller
    /// slice the stream at marker boundaries — which is what output capture
    /// needs, so a command's text starts at its `C` and ends at its `D`.
    pub fn offsetIn(s: *const Scanner, chunk: []const u8) usize {
        return chunk.len - s.pending.len;
    }

    /// Next marker in the current chunk, or null once it is exhausted. Parser
    /// state survives across chunks, so a sequence split by a read boundary is
    /// reported when its terminator finally arrives.
    pub fn next(s: *Scanner) ?Marker {
        while (s.pending.len > 0) {
            const byte = s.pending[0];
            s.pending = s.pending[1..];

            switch (s.state) {
                .ground => if (byte == esc) {
                    s.state = .escape;
                },

                .escape => switch (byte) {
                    ']' => {
                        s.state = .osc;
                        s.parser.reset();
                    },
                    // A second ESC restarts; anything else introduces some
                    // other sequence this scanner does not care about.
                    esc => {},
                    else => s.state = .ground,
                },

                .osc => switch (byte) {
                    bel => {
                        s.state = .ground;
                        if (s.finish(bel)) |marker| {
                            return marker;
                        }
                    },
                    esc => s.state = .osc_escape,
                    else => s.parser.next(byte),
                },

                .osc_escape => switch (byte) {
                    // ESC \ is ST, the other legal OSC terminator.
                    '\\' => {
                        s.state = .ground;
                        if (s.finish(st)) |marker| {
                            return marker;
                        }
                    },
                    // ESC ESC: abandon this one, the second ESC starts anew.
                    esc => {
                        s.parser.reset();
                        s.state = .escape;
                    },
                    // A bare ESC aborts the sequence without terminating it.
                    else => {
                        s.parser.reset();
                        s.state = .ground;
                    },
                },
            }
        }
        return null;
    }

    fn finish(s: *Scanner, terminator: u8) ?Marker {
        const command = s.parser.end(terminator) orelse return null;
        return switch (command.*) {
            .change_window_title => |title| .{ .title = title },
            .semantic_prompt => |prompt| switch (prompt.action) {
                .fresh_line_new_prompt, .prompt_start => .prompt_start,
                .end_prompt_start_input, .end_prompt_start_input_terminate_eol => .command_start,
                .end_input_start_output => .output_start,
                .end_command => .{
                    // The library reports the status as i32 because the option
                    // is free text; anything outside a POSIX status is treated
                    // as no status at all.
                    .command_end = if (prompt.readOption(.exit_code)) |code|
                        std.math.cast(u8, code)
                    else
                        null,
                },
                else => null,
            },
            else => null,
        };
    }
};

const esc = 0x1B;
const bel = 0x07;
const st = '\\';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Drains every marker a scanner finds across the given chunks, so a test can
/// state the chunk boundaries it wants to exercise.
fn collect(chunks: []const []const u8, out: *std.ArrayList(Marker), gpa: std.mem.Allocator) !void {
    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();

    for (chunks) |chunk| {
        scanner.feed(chunk);
        while (scanner.next()) |marker| {
            // Titles borrow the parser, so copy before the next call.
            const owned: Marker = switch (marker) {
                .title => |t| .{ .title = try gpa.dupe(u8, t) },
                else => marker,
            };
            try out.append(gpa, owned);
        }
    }
}

fn expectMarkers(chunks: []const []const u8, expected: []const Marker) !void {
    const gpa = testing.allocator;
    var found: std.ArrayList(Marker) = .empty;
    defer {
        for (found.items) |m| if (m == .title) gpa.free(m.title);
        found.deinit(gpa);
    }
    try collect(chunks, &found, gpa);

    try testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |want, got| {
        switch (want) {
            .title => |t| try testing.expectEqualStrings(t, got.title),
            else => try testing.expectEqual(want, got),
        }
    }
}

test "recognises the full OSC 133 lifecycle" {
    try expectMarkers(
        &.{"\x1b]133;A;cl=line\x07\x1b]133;B\x07\x1b]133;C\x07\x1b]133;D;0\x07"},
        &.{ .prompt_start, .command_start, .output_start, .{ .command_end = 0 } },
    );
}

test "reports a non-zero exit status" {
    try expectMarkers(&.{"\x1b]133;D;1\x07"}, &.{.{ .command_end = 1 }});
    try expectMarkers(&.{"\x1b]133;D;130\x07"}, &.{.{ .command_end = 130 }});
}

test "D without a status reports an unknown one" {
    try expectMarkers(&.{"\x1b]133;D\x07"}, &.{.{ .command_end = null }});
    try expectMarkers(&.{"\x1b]133;D;oops\x07"}, &.{.{ .command_end = null }});
}

test "accepts ST as well as BEL" {
    try expectMarkers(&.{"\x1b]133;C\x1b\\"}, &.{.output_start});
}

test "survives a sequence split across chunks" {
    // The proxy reads exactly 1024 bytes at a time, so this is the common case,
    // not an edge case. Split at every interior byte.
    const whole = "\x1b]133;D;7\x07";
    var i: usize = 1;
    while (i < whole.len) : (i += 1) {
        try expectMarkers(&.{ whole[0..i], whole[i..] }, &.{.{ .command_end = 7 }});
    }
}

test "captures the command line from the window title" {
    try expectMarkers(
        &.{"\x1b]2;sleep 0.4; echo listo\x07\x1b]133;C\x07"},
        &.{ .{ .title = "sleep 0.4; echo listo" }, .output_start },
    );
}

test "ignores other escape sequences" {
    // SGR, cursor moves and an unrelated OSC must not produce markers, and must
    // not disturb the marker that follows them.
    try expectMarkers(
        &.{"\x1b[1;32mgreen\x1b[0m\x1b[2J\x1b]7;file:///tmp\x07\x1b]133;B\x07"},
        &.{.command_start},
    );
}

test "does not confuse neighbouring OSC codes" {
    try expectMarkers(&.{"\x1b]1;icon\x07"}, &.{});
    try expectMarkers(&.{"\x1b]22;x\x07"}, &.{});
    try expectMarkers(&.{"\x1b]1337;File=x\x07"}, &.{});
}

test "an aborted sequence does not swallow the next one" {
    // ESC inside an OSC that is not ST aborts it.
    try expectMarkers(&.{"\x1b]133;D;0\x1b[0m\x1b]133;A\x07"}, &.{.prompt_start});
}

test "an empty title is still a title" {
    try expectMarkers(&.{"\x1b]2;\x07"}, &.{.{ .title = "" }});
}

test "an oversized payload does not break recovery" {
    // Rewritten from the hand-rolled version, which asserted the payload was
    // dropped at a private capacity constant. The contract is recovery, not the
    // capacity, so this asserts only that the next sequence still parses.
    const gpa = testing.allocator;
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(gpa);
    try chunk.appendSlice(gpa, "\x1b]2;");
    try chunk.appendNTimes(gpa, 'x', 64 * 1024);
    try chunk.append(gpa, 0x07);
    try chunk.appendSlice(gpa, "\x1b]133;A\x07");

    var found: std.ArrayList(Marker) = .empty;
    defer {
        for (found.items) |m| if (m == .title) gpa.free(m.title);
        found.deinit(gpa);
    }
    try collect(&.{chunk.items}, &found, gpa);

    try testing.expect(found.items.len >= 1);
    try testing.expectEqual(Marker.prompt_start, found.items[found.items.len - 1]);
}
