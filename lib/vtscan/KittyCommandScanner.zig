//! Finds where each Kitty graphics command ends in a PTY stream split at
//! arbitrary read boundaries, keeping its control data and the first bytes
//! of its payload, so a caller can act at the exact point a terminal would.
//! Framing is Ghostty's (`ApcFraming`): a command ends at ESC, ST, CAN, SUB
//! or a terminating C1 byte, aborted or not, and bytes Ghostty ignores
//! inside it are not kept. Nothing allocates.
const std = @import("std");
const ApcFraming = @import("ApcFraming.zig");
const KittyCommand = @import("KittyCommand.zig");
const KittyCommandScanner = @This();

/// Control data longer than this is reported truncated.
pub const control_capacity = 256;
/// Enough base64 for a PNG signature and its IHDR dimensions.
pub const payload_capacity = 64;

framing: ApcFraming = .{},
/// The current command's `;` was seen: content is payload from here on.
in_payload: bool = false,
// SAFETY: Command scanning writes each retained byte before increasing control_len; commands expose only that prefix.
control: [control_capacity]u8 = undefined,
control_len: usize = 0,
truncated: bool = false,
// SAFETY: Command scanning writes each retained byte before increasing payload_len; commands expose only that prefix.
payload: [payload_capacity]u8 = undefined,
payload_len: usize = 0,

/// The first command that ends inside `bytes`, or null when none does.
/// Call again with `bytes[command.end..]` for the next one.
///
/// ```zig
/// while (scanner.next(rest)) |command| { feed(rest[0..command.end]); rest = rest[command.end..]; }
/// ```
pub fn next(self: *KittyCommandScanner, bytes: []const u8) ?KittyCommand {
    var index: usize = 0;
    while (true) {
        const start = index;
        const inside = self.framing.inKitty();
        const transition = self.framing.advance(bytes, &index) orelse {
            if (inside) {
                self.capture(bytes[start..]);
            }

            return null;
        };

        switch (transition) {
            .kitty_started => {
                self.in_payload = false;
                self.control_len = 0;
                self.payload_len = 0;
                self.truncated = false;
            },
            .kitty_ended => {
                // The byte before `index` is the terminator.
                self.capture(bytes[start .. index - 1]);
                return .{
                    .end = index,
                    .control = self.control[0..self.control_len],
                    .payload = self.payload[0..self.payload_len],
                    .truncated = self.truncated,
                };
            },
        }
    }
}

// Keeps the command's content: control data up to `;`, then the first
// payload bytes. A long payload is not walked past what is kept.
fn capture(self: *KittyCommandScanner, content: []const u8) void {
    var rest = content;
    if (!self.in_payload) {
        const separator = std.mem.indexOfScalar(u8, rest, ';');
        const control = rest[0 .. separator orelse rest.len];
        for (control) |byte| {
            if (!ApcFraming.isContent(byte)) {
                continue;
            }

            if (self.control_len == self.control.len) {
                self.truncated = true;
                break;
            }

            self.control[self.control_len] = byte;
            self.control_len += 1;
        }

        const at = separator orelse return;
        self.in_payload = true;
        rest = rest[at + 1 ..];
    }

    for (rest) |byte| {
        if (self.payload_len == self.payload.len) {
            return;
        }

        if (ApcFraming.isContent(byte)) {
            self.payload[self.payload_len] = byte;
            self.payload_len += 1;
        }
    }
}
