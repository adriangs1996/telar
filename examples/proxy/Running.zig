/// A command between its OSC 133 C and D markers.
const Running = @This();
const source_namespace = @import("main.zig");
id: i64,
started_at: source_namespace.Io.Timestamp,
