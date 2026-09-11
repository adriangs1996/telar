const ConfigType = @import("../../proxy/Config.zig");
const InitOptions = @This();

config: ?ConfigType,
system_trusted: bool,
