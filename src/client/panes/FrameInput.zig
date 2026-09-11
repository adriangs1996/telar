const PaneIdType = @import("telar-core").PaneId;
const FrameInput = @This();

pane_id: PaneIdType = @enumFromInt(1),
id: u64 = 1,
base: u64 = 0,
cols: u16 = 2,
rows: u16 = 2,
character: u8 = 'a',
