const PaneInputTarget = @import("PaneInputTarget.zig").PaneInputTarget;
const PaneInputSource = @import("PaneInputSource.zig").PaneInputSource;
const keyinput = @import("keyinput");
const PaneInputCommand = @This();

target: PaneInputTarget,
source: PaneInputSource,
payload: PaneInputPayload,

const Key = keyinput.Key;

const PaneInputPayload = union(enum) {
    bytes: []const u8,
    key: Key,
};
