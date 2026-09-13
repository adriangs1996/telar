//! Groups whole graphemes by face, retaining contextual shaping within each span.
const core = @import("telar-core");
const FontSet = @import("FontSet.zig");
const FontRun = @import("FontRun.zig");
const FontRuns = @This();

fonts: *const FontSet,
iterator: core.GraphemeIterator,

/// Borrows slices of the original UTF-8; unsupported clusters remain in primary.
/// Example: `while (runs.next()) |run| { ... }`
pub fn next(runs: *FontRuns) ?FontRun {
    const start = runs.iterator.index;
    const first = runs.iterator.next() orelse return null;
    const id = runs.fonts.source(first.bytes);
    if (id != .primary) {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .font = id, .columns = first.width };
    }

    var columns: u32 = first.width;
    while (true) {
        const previous = runs.iterator.index;
        const cluster = runs.iterator.next() orelse break;
        if (runs.fonts.source(cluster.bytes) != id) {
            runs.iterator.index = previous;
            break;
        }

        columns += cluster.width;
    }

    return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .font = id, .columns = columns };
}
