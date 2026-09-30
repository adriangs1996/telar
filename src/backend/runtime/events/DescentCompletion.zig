const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
/// Whether the process at the other end of one client connection descends
/// from the pane generation it named, as an observation worker found by
/// walking that process's parents.
const DescentCompletion = @This();

client: ClientKey,
request_id: core.RequestId,
pane: PaneKey,
descends: bool,
