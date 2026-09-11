const ProbeInput = @This();
const std = @import("std");
const Cache = @import("Cache.zig");
const source_namespace = @import("root.zig");
const core = @import("telar-core");
process_group_id: ?std.c.pid_t,
shell_pid: std.c.pid_t,
previous: Cache,
manifests: *const source_namespace.Table = &core.agent_manifest.builtin_table,
