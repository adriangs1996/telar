const PaneIdType = @import("telar-core").PaneId;
const identity = @import("identity.zig");
const Credential = @This();

pane_id: PaneIdType,
pane_generation: u64,
token: [identity.token_bytes]u8,
