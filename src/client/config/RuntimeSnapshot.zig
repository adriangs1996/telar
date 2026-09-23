const data = @import("model");
const core = @import("telar-core");
const CommandSpec = @import("CommandSpec.zig");
const RuntimeSnapshot = @This();

graphics_pane_bytes: usize = core.max_image_bytes_per_pane,
graphics_global_bytes: usize = core.max_image_bytes_global,
history_path_bytes: [data.config_values.max_history_path_bytes]u8 = undefined,
history_path_len: u16 = 0,
proxy_enabled: bool = false,
proxy_ca_dir_bytes: [data.config_values.max_proxy_path_bytes]u8 = undefined,
proxy_ca_dir_len: u16 = 0,
proxy_intercept_hosts: data.ProxyInterceptHosts = data.config_values.defaultProxyInterceptHosts(),
proxy_capture_enabled: bool = false,
proxy_capture_max_part_bytes: usize = core.default_capture_part_bytes,
proxy_capture_max_exchange_bytes: usize = core.default_capture_exchange_bytes,
proxy_capture_max_total_bytes: usize = core.default_capture_total_bytes,
proxy_capture_join_timeout_ms: u32 = core.default_capture_join_timeout_ms,
agent_descriptions: CommandSpec = .{},
engine: CommandSpec = .{},
engine_idle_timeout_ms: u32 = data.config_values.default_engine_idle_timeout_ms,
agent_manifests: core.Table = core.builtin_table,
history_filters: core.Filters = .{},
history_output_capture: bool = false,
session_persist: bool = true,
session_resume_agents: bool = true,
session_path_bytes: [data.config_values.max_history_path_bytes]u8 = undefined,
session_path_len: u16 = 0,

pub fn historyPath(self: *const RuntimeSnapshot) ?[]const u8 {
    if (self.history_path_len == 0) {
        return null;
    }
    return self.history_path_bytes[0..self.history_path_len];
}

/// Configured checkpoint path, or null for the default next to history.
///
/// ```zig
/// const path = snapshot.sessionPath();
/// ```
pub fn sessionPath(self: *const RuntimeSnapshot) ?[]const u8 {
    if (self.session_path_len == 0) {
        return null;
    }
    return self.session_path_bytes[0..self.session_path_len];
}

pub fn proxyCaDir(self: *const RuntimeSnapshot) ?[]const u8 {
    if (self.proxy_ca_dir_len == 0) {
        return null;
    }
    return self.proxy_ca_dir_bytes[0..self.proxy_ca_dir_len];
}

/// Returns the exact hostnames that the runtime may TLS-intercept.
///
/// ```zig
/// const hosts = snapshot.proxyInterceptHosts(&storage);
/// ```
pub fn proxyInterceptHosts(self: *const RuntimeSnapshot, storage: *[core.max_intercept_hosts][]const u8) []const []const u8 {
    return self.proxy_intercept_hosts.slices(storage);
}
