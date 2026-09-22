const core = @import("telar-core");
const identity = @import("identity.zig");
const Credential = @This();

pane_id: core.PaneId,
pane_generation: u64,
token: [identity.token_bytes]u8,
