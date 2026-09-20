const std = @import("std");
const Widget = @import("../../change_review/Widget.zig");
const DiffHighlighter = @import("../../syntax/DiffHighlighter.zig");

const sources = [_][]const u8{ @embedFile("../../../../examples/change-review.diff"), @embedFile("../../../../examples/change-review-next.diff") };

/// Prepares standalone samples before native input or painting begins.
/// Example: `try fixture.prepare(widget, allocator, io);`
pub fn prepare(widget: *Widget, allocator: std.mem.Allocator, io: std.Io) !void {
    for (sources, 0..) |source, index| {
        try widget.model.revisions[index].load(source);
        var worker: DiffHighlighter = .{ .allocator = allocator, .io = io, .text = source, .roles = widget.roles[index][0..source.len] };
        try worker.run();
    }
    widget.model.selectFile(0);
}
