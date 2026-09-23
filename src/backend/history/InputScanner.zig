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

pub fn reset(self: *InputScanner) void {
    self.* = .{};
}

pub fn feed(self: *InputScanner, bytes: []const u8) Event {
    var event: Event = .{};
    for (bytes) |byte| self.feedByte(byte, &event);
    return event;
}

/// The typed text, or null when it could not be tracked exactly.
///
/// ```zig
/// const pending = scanner.typedText() orelse return;
/// ```
pub fn typedText(self: *const InputScanner) ?[]const u8 {
    if (!self.typed_exact) {
        return null;
    }
    return self.typed[0..self.typed_len];
}

fn feedByte(self: *InputScanner, byte: u8, event: *Event) void {
    switch (self.state) {
        .ground => switch (byte) {
            escape_ops.esc => {
                self.state = .escape;
                self.typed_exact = false;
            },
            '\r', '\n' => event.submitted = true,
            0x03 => event.cancelled = true,
            0x08, 0x7f => self.typed_len -|= 1,
            // Clear-screen repaints the line without changing it.
            0x0c => {},
            0x20...0x7e => self.recordTyped(byte),
            // Editing keys and multi-byte text change the line in ways
            // this scanner does not model.
            else => self.typed_exact = false,
        },
        .escape => if (byte == '[') {
            self.startCsi(.csi);
        } else {
            self.state = .ground;
        },
        .csi => self.csiByte(byte, false),
        .paste => {
            if (byte == escape_ops.esc) {
                self.state = .paste_escape;
            }
        },
        .paste_escape => if (byte == '[') {
            self.startCsi(.paste_csi);
        } else {
            self.state = .paste;
        },
        .paste_csi => self.csiByte(byte, true),
    }
}

fn recordTyped(self: *InputScanner, byte: u8) void {
    if (self.typed_len == max_typed_bytes) {
        self.typed_exact = false;
        return;
    }

    self.typed[self.typed_len] = byte;
    self.typed_len += 1;
}

fn startCsi(self: *InputScanner, state: State) void {
    self.state = state;
    self.parameter = 0;
    self.has_parameter = false;
}

fn csiByte(self: *InputScanner, byte: u8, from_paste: bool) void {
    if (byte >= '0' and byte <= '9') {
        self.has_parameter = true;
        self.parameter = std.math.mul(u16, self.parameter, 10) catch std.math.maxInt(u16);
        self.parameter = std.math.add(u16, self.parameter, byte - '0') catch std.math.maxInt(u16);
        return;
    }
    if (byte == '~' and self.has_parameter) {
        if (!from_paste and self.parameter == 200) {
            self.state = .paste;
            return;
        }
        if (from_paste and self.parameter == 201) {
            self.state = .ground;
            return;
        }
    }
    self.state = if (from_paste) .paste else .ground;
}
