const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");

request_id: core.RequestId,
pane_id: core.PaneId,
pane_generation: u64,
target: ClientKey,
