const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const MarkerScreen = @This();

buffer: *const cellgrid.Buffer,
cursor: core.Cursor,
