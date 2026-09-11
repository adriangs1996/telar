const Scanner = @This();
const vt = @import("ghostty-vt");
const std = @import("std");
const source_namespace = @import("osc.zig");
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
pub fn next(s: *Scanner) ?source_namespace.Marker {
    while (s.pending.len > 0) {
        const byte = s.pending[0];
        s.pending = s.pending[1..];

        switch (s.state) {
            .ground => if (byte == source_namespace.esc) {
                s.state = .escape;
            },

            .escape => switch (byte) {
                ']' => {
                    s.state = .osc;
                    s.parser.reset();
                },
                // A second ESC restarts; anything else introduces some
                // other sequence this scanner does not care about.
                source_namespace.esc => {},
                else => s.state = .ground,
            },

            .osc => switch (byte) {
                source_namespace.bel => {
                    s.state = .ground;
                    if (s.finish(source_namespace.bel)) |marker| {
                        return marker;
                    }
                },
                source_namespace.esc => s.state = .osc_escape,
                else => s.parser.next(byte),
            },

            .osc_escape => switch (byte) {
                // ESC \ is ST, the other legal OSC terminator.
                '\\' => {
                    s.state = .ground;
                    if (s.finish(source_namespace.st)) |marker| {
                        return marker;
                    }
                },
                // ESC ESC: abandon this one, the second ESC starts anew.
                source_namespace.esc => {
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

fn finish(s: *Scanner, terminator: u8) ?source_namespace.Marker {
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
