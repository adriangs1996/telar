const FrameInput = @This();
const source_namespace = @import("tests.zig");
pane_id: source_namespace.schema.PaneId = @enumFromInt(1),
id: u64 = 1,
base: u64 = 0,
cols: u16 = 2,
rows: u16 = 2,
character: u8 = 'a',
