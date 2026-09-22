const core = @import("telar-core");
const Screen = @import("Screen.zig");
/// The run sink most composition layers want: copy the run straight into the
/// screen's back buffer through `patchCells`, so damage stays exact.
const PatchSink = @This();

screen: *Screen,
source_row: []const core.Cell,
/// Linear cell index of `source_row[0]` in the screen buffer.
base: usize,

pub fn copyRun(sink: *PatchSink, run_start: u16, count: u16) !void {
    const destination = try sink.screen.patchCells(@intCast(sink.base + run_start), count);
    @memcpy(destination, sink.source_row[run_start..][0..count]);
}
