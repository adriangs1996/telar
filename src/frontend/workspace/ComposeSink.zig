const core = @import("telar-core");
const PatchSink = @import("../presentation/PatchSink.zig");
/// Copies each changed run into the composed buffer and the screen at once,
/// so the composed cache and the terminal patch can never disagree.
const ComposeSink = @This();

patch: PatchSink,
composed_row: []core.Cell,

pub fn copyRun(self: *ComposeSink, run_start: u16, count: u16) !void {
    @memcpy(
        self.composed_row[run_start..][0..count],
        self.patch.source_row[run_start..][0..count],
    );
    try self.patch.copyRun(run_start, count);
}
