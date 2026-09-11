const Snapshot = @This();
const source_namespace = @import("playback_support.zig");
configuration: source_namespace.Config,
active: bool,
queued: ?source_namespace.Kind,
