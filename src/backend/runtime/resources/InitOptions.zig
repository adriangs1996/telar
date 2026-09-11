const InitOptions = @This();
const source_namespace = @import("proxy.zig");
config: ?source_namespace.Config,
system_trusted: bool,
