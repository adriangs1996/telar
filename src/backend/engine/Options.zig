const Options = @This();

arguments: []const []const u8,
/// Deadline for one prompt, from the command write to the assistant text.
timeout_ms: u32,
/// Idle interval after which the child is killed. The runtime asks for
/// the check on its own cadence; the engine never runs a timer.
idle_timeout_ms: u32,
