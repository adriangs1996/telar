const cellgrid = @import("cellgrid");
const Screen = @import("Screen.zig");
/// The run sink most composition layers want: copy the run straight into the
/// screen's back buffer through `patchCells`, so damage stays exact.
const PatchSink = @This();

screen: *Screen,
source_row: []const cellgrid.Cell,
/// Linear cell index of `source_row[0]` in the screen buffer.
base: usize,

pub fn copyRun(self: *PatchSink, run_start: u16, count: u16) !void {
    const destination = try self.screen.patchCells(@intCast(self.base + run_start), count);
    @memcpy(destination, self.source_row[run_start..][0..count]);
}
