const cmdcapture = @import("cmdcapture");
const Clock = cmdcapture.Clock;
const InputObservation = @This();

bytes: []const u8,
shell_foreground: bool,
clock: Clock,
