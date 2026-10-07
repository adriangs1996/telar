const cmdcapture = @import("cmdcapture");
const Clock = cmdcapture.Clock;

bytes: []const u8,
shell_foreground: ?bool,
clock: Clock,
