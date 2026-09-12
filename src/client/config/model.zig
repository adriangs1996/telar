//! Validated configuration values shared by the Lua compiler and client.

const GenericBinding = @import("../input/GenericBinding.zig").Type;
const ActionType = @import("../input/action.zig").Action;
const ProxyInterceptHosts = @import("ProxyInterceptHosts.zig");
const max_intercept_hosts_module = @import("telar-core").max_intercept_hosts;
const std = @import("std");

pub const default_memory_limit: usize = 16 * 1024 * 1024;
pub const default_load_instruction_limit: u64 = 1_000_000;
pub const max_bindings = 256;
pub const max_binding_keys = 5;

pub const max_plugins = 32;
pub const max_plugin_path_bytes = 512;
pub const max_history_path_bytes = 1024;
pub const max_proxy_path_bytes = 1024;

pub const default_proxy_intercept_hosts = [_][]const u8{
    "api.anthropic.com",
    "api.openai.com",
    "chatgpt.com",
};
pub const max_agent_description_command_args = 32;
pub const max_agent_description_command_bytes = 4096;
pub const max_bar_callbacks = 64;
pub const default_agent_description_timeout_ms: u32 = 15_000;
pub const default_engine_idle_timeout_ms: u32 = 300_000;
pub const min_engine_idle_timeout_ms: u32 = 10_000;
pub const max_engine_idle_timeout_ms: u32 = 3_600_000;
pub const min_agent_description_timeout_ms: u32 = 1_000;
pub const max_agent_description_timeout_ms: u32 = 60_000;

pub const ConfiguredBinding = GenericBinding(ActionType, max_binding_keys);

pub fn defaultProxyInterceptHosts() ProxyInterceptHosts {
    var hosts: ProxyInterceptHosts = .{};
    for (default_proxy_intercept_hosts) |host| {
        hosts.append(host) catch unreachable;
    }

    return hosts;
}

test "proxy intercept hosts are compact, canonical, sorted, and unique" {
    var hosts: ProxyInterceptHosts = .{};
    try hosts.append("Updates.Example.com");
    try hosts.append("api.example.com");
    try hosts.append("API.EXAMPLE.COM");
    hosts.sortAndDeduplicate();

    var storage: [max_intercept_hosts_module][]const u8 = undefined;
    const sorted = hosts.slices(&storage);
    try std.testing.expectEqual(@as(usize, 2), sorted.len);
    try std.testing.expectEqualStrings("api.example.com", sorted[0]);
    try std.testing.expectEqualStrings("updates.example.com", sorted[1]);
}

test "default proxy intercept hosts cover Claude Code and Codex APIs" {
    const hosts = defaultProxyInterceptHosts();
    var storage: [max_intercept_hosts_module][]const u8 = undefined;
    const configured = hosts.slices(&storage);

    try std.testing.expectEqual(default_proxy_intercept_hosts.len, configured.len);
    for (default_proxy_intercept_hosts, configured) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

pub const max_window_title_bytes = 128;
