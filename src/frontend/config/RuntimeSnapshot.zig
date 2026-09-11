const RuntimeSnapshot = @This();
const core = @import("telar-core");
const source_namespace = @import("model.zig");
const ProxyInterceptHosts = @import("ProxyInterceptHosts.zig");
const CommandSpec = @import("CommandSpec.zig");
graphics_pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
graphics_global_bytes: usize = core.graphics.max_image_bytes_global,
history_path_bytes: [source_namespace.max_history_path_bytes]u8 = undefined,
history_path_len: u16 = 0,
proxy_enabled: bool = false,
proxy_ca_dir_bytes: [source_namespace.max_proxy_path_bytes]u8 = undefined,
proxy_ca_dir_len: u16 = 0,
proxy_intercept_hosts: ProxyInterceptHosts = source_namespace.defaultProxyInterceptHosts(),
proxy_capture_enabled: bool = false,
proxy_capture_max_part_bytes: usize = core.proxy.default_capture_part_bytes,
proxy_capture_max_exchange_bytes: usize = core.proxy.default_capture_exchange_bytes,
proxy_capture_max_total_bytes: usize = core.proxy.default_capture_total_bytes,
proxy_capture_join_timeout_ms: u32 = core.proxy.default_capture_join_timeout_ms,
agent_descriptions: CommandSpec = .{},
engine: CommandSpec = .{},
engine_idle_timeout_ms: u32 = source_namespace.default_engine_idle_timeout_ms,
agent_manifests: core.agent_manifest.Table = core.agent_manifest.builtin_table,
history_filters: core.history_filter.Filters = .{},
history_output_capture: bool = false,
session_persist: bool = true,
session_resume_agents: bool = true,
session_path_bytes: [source_namespace.max_history_path_bytes]u8 = undefined,
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
pub fn proxyInterceptHosts(snapshot: *const RuntimeSnapshot, storage: *[source_namespace.max_proxy_intercept_hosts][]const u8) []const []const u8 {
    return snapshot.proxy_intercept_hosts.slices(storage);
}
