const PaneInputTarget = @import("../types/PaneInputTarget.zig").PaneInputTarget;
const PaneInputSource = @import("../types/PaneInputSource.zig").PaneInputSource;
const PaneInputPayload = @import("../types/PaneInputPayload.zig").PaneInputPayload;
const PaneInputCommand = @This();

target: PaneInputTarget,
source: PaneInputSource,
payload: PaneInputPayload,
