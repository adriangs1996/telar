const core = @import("telar-core");
const std = @import("std");
const Cache = @import("Cache.zig");
const ProbeInput = @This();

process_group_id: ?std.c.pid_t,
previous: Cache,
manifests: *const core.Table = &core.builtin_table,
