const TrackerType = @import("../../../agent/Tracker.zig");
const State = @import("State.zig");
const CommandType = @import("../../../agent/Command.zig");
const Resources = @This();

agents: *TrackerType,
state: *State,
command: ?CommandType,
