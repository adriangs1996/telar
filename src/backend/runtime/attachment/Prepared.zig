const GraphicsCounts = @import("GraphicsCounts.zig");
const Prepared = @This();

bytes: []const u8,
effect: Effect,

const Effect = union(enum) {
    cwd: u64,
    foreground: u64,
    title: u64,
    progress: u64,
    cells,
    exit,
    graphics: GraphicsCounts,
};
