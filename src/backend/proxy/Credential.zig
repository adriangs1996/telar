const Credential = @This();
const source_namespace = @import("identity.zig");
pane_id: source_namespace.schema.PaneId,
pane_generation: u64,
token: [source_namespace.token_bytes]u8,
