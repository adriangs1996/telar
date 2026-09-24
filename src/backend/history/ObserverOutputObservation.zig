const cmdcapture = @import("cmdcapture");
const Clock = cmdcapture.Clock;
const OutputObservation = @This();

bytes: []const u8,
shell_foreground: ?bool,
clock: Clock,
