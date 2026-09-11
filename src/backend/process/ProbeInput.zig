const std = @import("std");
const Cache = @import("Cache.zig");
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const ProbeInput = @This();

process_group_id: ?std.c.pid_t,
shell_pid: std.c.pid_t,
previous: Cache,
manifests: *const TableType = &builtin_table_module,
