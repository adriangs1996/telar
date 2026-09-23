const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");
/// Plain text of the active screen, captured bottom-up so the rows nearest
/// the prompt are complete whenever the screen exceeds the capacity.
const Sample = @This();

pub const capacity = 16 * 1024;

bytes: [capacity]u8 = undefined,
start: usize = capacity,

/// Replaces the sample with the terminal's current active screen. Blank
/// cells become spaces, a hard line break becomes one space and a
/// soft-wrapped row continues into the next one without a separator.
///
/// ```zig
/// sample.capture(&observer.terminal);
/// const signal = sample.signal(observer.manifests);
/// ```
pub fn capture(self: *Sample, terminal: *const vt.Terminal) void {
    self.start = capacity;
    const screen = terminal.screens.active;
    var y: usize = terminal.rows;

    while (y != 0) {
        y -= 1;
        const pin = screen.pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse continue;

        if (self.start != capacity and !pin.rowAndCell().row.wrap) {
            if (!self.prepend(" ")) {
                return;
            }
        }

        if (!self.prependRow(pin.cells(.all))) {
            return;
        }
    }
}

pub fn text(self: *const Sample) []const u8 {
    return self.bytes[self.start..];
}

/// Applies the manifest table's heuristics to the captured screen.
///
/// ```zig
/// const signal = sample.signal(&core.agent_manifest.builtin_table);
/// ```
pub fn signal(self: *const Sample, table: *const core.Table) ?core.Signal {
    return table.detect(self.text());
}

fn prependRow(self: *Sample, cells: []const vt.Cell) bool {
    var index = cells.len;
    while (index != 0 and cells[index - 1].codepoint() == 0) : (index -= 1) {}

    while (index != 0) {
        index -= 1;
        const codepoint = cells[index].codepoint();

        if (codepoint == 0) {
            if (!self.prepend(" ")) {
                return false;
            }
            continue;
        }

        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &encoded) catch replaced: {
            encoded[0] = '?';
            break :replaced 1;
        };

        if (!self.prepend(encoded[0..len])) {
            return false;
        }
    }

    return true;
}

fn prepend(self: *Sample, bytes: []const u8) bool {
    if (bytes.len > self.start) {
        return false;
    }

    self.start -= bytes.len;
    @memcpy(self.bytes[self.start..][0..bytes.len], bytes);
    return true;
}
