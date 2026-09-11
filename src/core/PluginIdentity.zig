const plugin = @import("plugin.zig");
const PluginIdentity = @This();

id: []const u8,
digest: plugin.Digest,
