const EventType = @import("Event.zig");
const escape_ops = @import("escape.zig");
const std = @import("std");
/// Classifies keyboard bytes going *to* a child: submits, cancels, and
/// bracketed paste. Bracketed paste identifies paste; newlines inside a paste
/// are content, never a submit - the invariant that timing heuristics must
/// not decide what a paste is.
const InputScanner = @This();

state: State = .ground,
parameter: u16 = 0,
has_parameter: bool = false,
/// Printable ASCII typed since the last reset, with backspaces applied.
/// This is what a line editor re-echoes when it takes over input that
/// arrived before it started. It is exact only while `typed_exact` holds:
/// multi-byte text, pastes and kill keys are not modeled.
typed: [max_typed_bytes]u8 = undefined,
typed_len: u8 = 0,
typed_exact: bool = true,

pub const max_typed_bytes = 255;

const State = enum { ground, escape, csi, paste, paste_escape, paste_csi };
pub const Event = @import("Event.zig");

pub fn reset(scanner: *InputScanner) void {
    scanner.* = .{};
}

pub fn feed(scanner: *InputScanner, bytes: []const u8) EventType {
    var event: EventType = .{};
    for (bytes) |byte| scanner.feedByte(byte, &event);
    return event;
}

/// The typed text, or null when it could not be tracked exactly.
///
/// ```zig
/// const pending = scanner.typedText() orelse return;
/// ```
pub fn typedText(scanner: *const InputScanner) ?[]const u8 {
    if (!scanner.typed_exact) {
        return null;
    }
    return scanner.typed[0..scanner.typed_len];
}

fn feedByte(scanner: *InputScanner, byte: u8, event: *EventType) void {
    switch (scanner.state) {
        .ground => switch (byte) {
            escape_ops.esc => {
                scanner.state = .escape;
                scanner.typed_exact = false;
            },
            '\r', '\n' => event.submitted = true,
            0x03 => event.cancelled = true,
            0x08, 0x7f => scanner.typed_len -|= 1,
            // Clear-screen repaints the line without changing it.
            0x0c => {},
            0x20...0x7e => scanner.recordTyped(byte),
            // Editing keys and multi-byte text change the line in ways
            // this scanner does not model.
            else => scanner.typed_exact = false,
        },
        .escape => if (byte == '[') {
            scanner.startCsi(.csi);
        } else {
            scanner.state = .ground;
        },
        .csi => scanner.csiByte(byte, false),
        .paste => {
            if (byte == escape_ops.esc) {
                scanner.state = .paste_escape;
            }
        },
        .paste_escape => if (byte == '[') {
            scanner.startCsi(.paste_csi);
        } else {
            scanner.state = .paste;
        },
        .paste_csi => scanner.csiByte(byte, true),
    }
}

fn recordTyped(scanner: *InputScanner, byte: u8) void {
    if (scanner.typed_len == max_typed_bytes) {
        scanner.typed_exact = false;
        return;
    }

    scanner.typed[scanner.typed_len] = byte;
    scanner.typed_len += 1;
}

fn startCsi(scanner: *InputScanner, state: State) void {
    scanner.state = state;
    scanner.parameter = 0;
    scanner.has_parameter = false;
}

fn csiByte(scanner: *InputScanner, byte: u8, from_paste: bool) void {
    if (byte >= '0' and byte <= '9') {
        scanner.has_parameter = true;
        scanner.parameter = std.math.mul(u16, scanner.parameter, 10) catch std.math.maxInt(u16);
        scanner.parameter = std.math.add(u16, scanner.parameter, byte - '0') catch std.math.maxInt(u16);
        return;
    }
    if (byte == '~' and scanner.has_parameter) {
        if (!from_paste and scanner.parameter == 200) {
            scanner.state = .paste;
            return;
        }
        if (from_paste and scanner.parameter == 201) {
            scanner.state = .ground;
            return;
        }
    }
    scanner.state = if (from_paste) .paste else .ground;
}
