const PatchSinkType = @import("../presentation/PatchSink.zig");
const CellType = @import("telar-core").Cell;
/// Copies each changed run into the composed buffer and the screen at once,
/// so the composed cache and the terminal patch can never disagree.
const ComposeSink = @This();

patch: PatchSinkType,
composed_row: []CellType,

pub fn copyRun(sink: *ComposeSink, run_start: u16, count: u16) !void {
    @memcpy(
        sink.composed_row[run_start..][0..count],
        sink.patch.source_row[run_start..][0..count],
    );
    try sink.patch.copyRun(run_start, count);
}
