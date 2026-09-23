const Config = @import("../../proxy/Config.zig");
const InitOptions = @This();

config: ?Config,
system_trusted: bool,
