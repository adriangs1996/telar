/// Plain text of the active screen, captured bottom-up so the rows nearest
/// the prompt are complete whenever the screen exceeds the capacity.
const Sample = @This();
const vt = @import("ghostty-vt");
const source_namespace = @import("agent_detection.zig");
const std = @import("std");
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
pub fn capture(sample: *Sample, terminal: *const vt.Terminal) void {
    sample.start = capacity;
    const screen = terminal.screens.active;
    var y: usize = terminal.rows;

    while (y != 0) {
        y -= 1;
        const pin = screen.pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse continue;

        if (sample.start != capacity and !pin.rowAndCell().row.wrap) {
            if (!sample.prepend(" ")) {
                return;
            }
        }

        if (!sample.prependRow(pin.cells(.all))) {
            return;
        }
    }
}

pub fn text(sample: *const Sample) []const u8 {
    return sample.bytes[sample.start..];
}

/// Applies the manifest table's heuristics to the captured screen.
///
/// ```zig
/// const signal = sample.signal(&core.agent_manifest.builtin_table);
/// ```
pub fn signal(sample: *const Sample, table: *const source_namespace.Table) ?source_namespace.Signal {
    return table.detect(sample.text());
}

fn prependRow(sample: *Sample, cells: []const vt.Cell) bool {
    var index = cells.len;
    while (index != 0 and cells[index - 1].codepoint() == 0) : (index -= 1) {}

    while (index != 0) {
        index -= 1;
        const codepoint = cells[index].codepoint();

        if (codepoint == 0) {
            if (!sample.prepend(" ")) {
                return false;
            }
            continue;
        }

        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &encoded) catch replaced: {
            encoded[0] = '?';
            break :replaced 1;
        };

        if (!sample.prepend(encoded[0..len])) {
            return false;
        }
    }

    return true;
}

fn prepend(sample: *Sample, bytes: []const u8) bool {
    if (bytes.len > sample.start) {
        return false;
    }

    sample.start -= bytes.len;
    @memcpy(sample.bytes[sample.start..][0..bytes.len], bytes);
    return true;
}
