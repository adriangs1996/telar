//! Validated configuration values shared by the Lua compiler and client.
const keyinput = @import("keyinput");

const data = @import("../model.zig");
const core = @import("telar-core");
const GenericBinding = keyinput.GenericBinding;
const ProxyInterceptHosts = @import("ProxyInterceptHosts.zig");
const std = @import("std");

pub const max_bindings = 256;
pub const max_binding_keys = 5;

pub const max_plugins = 32;
pub const max_plugin_path_bytes = 512;
pub const max_history_path_bytes = 1024;
pub const max_editor_bytes = 4096;
pub const max_proxy_path_bytes = 1024;

pub const max_agent_description_command_args = 32;
pub const max_agent_description_command_bytes = 4096;
/// One render per bar position, one per panel and one list per pick, so a
/// configuration within the other bar limits never runs out.
pub const max_bar_callbacks = std.enums.values(data.bar_values.Position).len + data.bar_values.max_panels + data.bar_values.max_picks;
pub const default_agent_description_timeout_ms: u32 = 15_000;
pub const default_engine_idle_timeout_ms: u32 = 300_000;
pub const min_engine_idle_timeout_ms: u32 = 10_000;
pub const max_engine_idle_timeout_ms: u32 = 3_600_000;
pub const min_agent_description_timeout_ms: u32 = 1_000;
pub const max_agent_description_timeout_ms: u32 = 60_000;

pub const ConfiguredBinding = GenericBinding(data.Action, max_binding_keys);

/// The proxy intercepts nothing until `intercept_hosts` names a host: every
/// CONNECT stays an authenticated TCP tunnel.
pub fn defaultProxyInterceptHosts() ProxyInterceptHosts {
    return .{};
}

test "proxy intercept hosts are compact, canonical, sorted, and unique" {
    var hosts: ProxyInterceptHosts = .{};
    try hosts.append("Updates.Example.com");
    try hosts.append("api.example.com");
    try hosts.append("API.EXAMPLE.COM");
    hosts.sortAndDeduplicate();

    var storage: [core.max_intercept_hosts][]const u8 = undefined;
    const sorted = hosts.slices(&storage);
    try std.testing.expectEqual(@as(usize, 2), sorted.len);
    try std.testing.expectEqualStrings("api.example.com", sorted[0]);
    try std.testing.expectEqualStrings("updates.example.com", sorted[1]);
}

test "the proxy intercepts no host by default" {
    const hosts = defaultProxyInterceptHosts();
    var storage: [core.max_intercept_hosts][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), hosts.slices(&storage).len);
}

pub const max_window_title_bytes = 128;
