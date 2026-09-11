const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const max_image_bytes_global_module = @import("telar-core").max_image_bytes_global;
const model = @import("model.zig");
const ProxyInterceptHosts = @import("ProxyInterceptHosts.zig");
const default_capture_part_bytes_module = @import("telar-core").default_capture_part_bytes;
const default_capture_exchange_bytes_module = @import("telar-core").default_capture_exchange_bytes;
const default_capture_total_bytes_module = @import("telar-core").default_capture_total_bytes;
const default_capture_join_timeout_ms_module = @import("telar-core").default_capture_join_timeout_ms;
const CommandSpec = @import("CommandSpec.zig");
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const FiltersType = @import("telar-core").Filters;
const max_intercept_hosts = @import("telar-core").max_intercept_hosts;
const RuntimeSnapshot = @This();

graphics_pane_bytes: usize = max_image_bytes_per_pane_module,
graphics_global_bytes: usize = max_image_bytes_global_module,
history_path_bytes: [model.max_history_path_bytes]u8 = undefined,
history_path_len: u16 = 0,
proxy_enabled: bool = false,
proxy_ca_dir_bytes: [model.max_proxy_path_bytes]u8 = undefined,
proxy_ca_dir_len: u16 = 0,
proxy_intercept_hosts: ProxyInterceptHosts = model.defaultProxyInterceptHosts(),
proxy_capture_enabled: bool = false,
proxy_capture_max_part_bytes: usize = default_capture_part_bytes_module,
proxy_capture_max_exchange_bytes: usize = default_capture_exchange_bytes_module,
proxy_capture_max_total_bytes: usize = default_capture_total_bytes_module,
proxy_capture_join_timeout_ms: u32 = default_capture_join_timeout_ms_module,
agent_descriptions: CommandSpec = .{},
engine: CommandSpec = .{},
engine_idle_timeout_ms: u32 = model.default_engine_idle_timeout_ms,
agent_manifests: TableType = builtin_table_module,
history_filters: FiltersType = .{},
history_output_capture: bool = false,
session_persist: bool = true,
session_resume_agents: bool = true,
session_path_bytes: [model.max_history_path_bytes]u8 = undefined,
session_path_len: u16 = 0,

pub fn historyPath(snapshot: *const RuntimeSnapshot) ?[]const u8 {
    if (snapshot.history_path_len == 0) {
        return null;
    }
    return snapshot.history_path_bytes[0..snapshot.history_path_len];
}

/// Configured checkpoint path, or null for the default next to history.
///
/// ```zig
/// const path = snapshot.sessionPath();
/// ```
pub fn sessionPath(snapshot: *const RuntimeSnapshot) ?[]const u8 {
    if (snapshot.session_path_len == 0) {
        return null;
    }
    return snapshot.session_path_bytes[0..snapshot.session_path_len];
}

pub fn proxyCaDir(snapshot: *const RuntimeSnapshot) ?[]const u8 {
    if (snapshot.proxy_ca_dir_len == 0) {
        return null;
    }
    return snapshot.proxy_ca_dir_bytes[0..snapshot.proxy_ca_dir_len];
}

/// Returns the exact hostnames that the runtime may TLS-intercept.
///
/// ```zig
/// const hosts = snapshot.proxyInterceptHosts(&storage);
/// ```
pub fn proxyInterceptHosts(snapshot: *const RuntimeSnapshot, storage: *[max_intercept_hosts][]const u8) []const []const u8 {
    return snapshot.proxy_intercept_hosts.slices(storage);
}
