//! Validated configuration values shared by the Lua compiler and client.

const std = @import("std");
const core = @import("telar-core");
const bars = @import("../bars/root.zig");
const input = @import("../input/root.zig");
const sound = @import("../sound/root.zig");
const notifications = @import("../notifications/root.zig");
const action = input.action;
const keybind = input.keybind;
const kitty = @import("../graphics/root.zig").kitty;
const icons = @import("../ui/root.zig").icons;
const theme = @import("../ui/root.zig").theme;

pub const default_memory_limit: usize = 16 * 1024 * 1024;
pub const default_load_instruction_limit: u64 = 1_000_000;
pub const max_bindings = 256;
pub const max_binding_keys = 5;
pub const max_callback_effects = 16;
pub const max_expression_keys = 16;
pub const max_expression_paste_bytes = 4096;
pub const max_plugins = 32;
pub const max_plugin_path_bytes = 512;
pub const max_history_path_bytes = 1024;
pub const max_proxy_path_bytes = 1024;
pub const max_proxy_intercept_hosts = core.proxy.max_intercept_hosts;
pub const max_proxy_intercept_host_bytes = core.proxy.max_hostname_bytes;
pub const max_proxy_intercept_bytes = core.proxy.max_intercept_bytes;
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

pub const ConfiguredBinding = keybind.Binding(action.Action, max_binding_keys);

pub const Diagnostic = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(diagnostic: *const Diagnostic) []const u8 {
        return diagnostic.buffer[0..diagnostic.len];
    }

    pub fn set(diagnostic: *Diagnostic, comptime format: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(&diagnostic.buffer, format, args) catch
            "configuration error";
        diagnostic.len = rendered.len;
    }
};

pub const PluginSpec = struct {
    path_bytes: [max_plugin_path_bytes]u8 = undefined,
    path_len: u16,
    enabled: bool = true,

    pub fn path(spec: *const PluginSpec) []const u8 {
        return spec.path_bytes[0..spec.path_len];
    }
};

/// One configured subprocess: a bounded argv plus its deadline.
pub const CommandSpec = struct {
    bytes: [max_agent_description_command_bytes]u8 = undefined,
    byte_len: u16 = 0,
    offsets: [max_agent_description_command_args]u16 = @splat(0),
    lengths: [max_agent_description_command_args]u16 = @splat(0),
    argument_count: u8 = 0,
    timeout_ms: u32 = default_agent_description_timeout_ms,

    pub fn enabled(command: *const CommandSpec) bool {
        return command.argument_count != 0;
    }

    pub fn argument(command: *const CommandSpec, index: usize) ?[]const u8 {
        if (index >= command.argument_count) {
            return null;
        }
        const start = command.offsets[index];
        return command.bytes[start .. start + command.lengths[index]];
    }

    pub fn arguments(command: *const CommandSpec, storage: *[max_agent_description_command_args][]const u8) []const []const u8 {
        for (0..command.argument_count) |index| storage[index] = command.argument(index).?;
        return storage[0..command.argument_count];
    }
};

pub const AgentDescriptionCommand = CommandSpec;
pub const SoundConfig = sound.Config;
pub const NotificationDelivery = notifications.Delivery;

pub const ProxyInterceptHosts = struct {
    const Reference = struct {
        offset: u16,
        len: u8,
    };

    bytes: [max_proxy_intercept_bytes]u8 = undefined,
    byte_len: u16 = 0,
    references: [max_proxy_intercept_hosts]Reference = undefined,
    count: u16 = 0,

    comptime {
        std.debug.assert(max_proxy_intercept_bytes <= std.math.maxInt(u16));
    }

    /// Appends one canonical hostname within the fixed count and byte budgets.
    ///
    /// ```zig
    /// try hosts.append("api.openai.com");
    /// ```
    pub fn append(hosts: *ProxyInterceptHosts, host: []const u8) !void {
        if (hosts.count == max_proxy_intercept_hosts) {
            return error.TooManyProxyInterceptHosts;
        }

        if (host.len == 0 or host.len > max_proxy_intercept_host_bytes) {
            return error.InvalidProxyInterceptHost;
        }

        const end = @as(usize, hosts.byte_len) + host.len;
        if (end > hosts.bytes.len) {
            return error.ProxyInterceptHostsTooLarge;
        }

        const offset = hosts.byte_len;
        for (host, hosts.bytes[offset..end]) |byte, *destination| {
            destination.* = std.ascii.toLower(byte);
        }

        hosts.references[hosts.count] = .{
            .offset = offset,
            .len = @intCast(host.len),
        };
        hosts.byte_len = @intCast(end);
        hosts.count += 1;
    }

    /// Sorts the hostnames for binary search and removes case-insensitive
    /// duplicates.
    ///
    /// ```zig
    /// hosts.sortAndDeduplicate();
    /// ```
    pub fn sortAndDeduplicate(hosts: *ProxyInterceptHosts) void {
        std.mem.sort(
            Reference,
            hosts.references[0..hosts.count],
            hosts,
            struct {
                fn lessThan(context: *const ProxyInterceptHosts, left: Reference, right: Reference) bool {
                    return core.proxy.orderHostname(
                        context.value(left),
                        context.value(right),
                    ) == .lt;
                }
            }.lessThan,
        );

        var unique_count: usize = 0;
        for (hosts.references[0..hosts.count]) |reference| {
            if (unique_count != 0 and core.proxy.orderHostname(
                hosts.value(hosts.references[unique_count - 1]),
                hosts.value(reference),
            ) == .eq) {
                continue;
            }

            hosts.references[unique_count] = reference;
            unique_count += 1;
        }

        hosts.count = @intCast(unique_count);
    }

    /// Materializes borrowed slices for the runtime bootstrap. The returned
    /// strings remain owned by this configuration snapshot.
    ///
    /// ```zig
    /// const configured = hosts.slices(&storage);
    /// ```
    pub fn slices(hosts: *const ProxyInterceptHosts, storage: *[max_proxy_intercept_hosts][]const u8) []const []const u8 {
        for (hosts.references[0..hosts.count], 0..) |reference, index| {
            storage[index] = hosts.value(reference);
        }

        return storage[0..hosts.count];
    }

    fn value(hosts: *const ProxyInterceptHosts, reference: Reference) []const u8 {
        return hosts.bytes[reference.offset..][0..reference.len];
    }
};

fn defaultProxyInterceptHosts() ProxyInterceptHosts {
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

    var storage: [max_proxy_intercept_hosts][]const u8 = undefined;
    const sorted = hosts.slices(&storage);
    try std.testing.expectEqual(@as(usize, 2), sorted.len);
    try std.testing.expectEqualStrings("api.example.com", sorted[0]);
    try std.testing.expectEqualStrings("updates.example.com", sorted[1]);
}

test "default proxy intercept hosts cover Claude Code and Codex APIs" {
    const hosts = defaultProxyInterceptHosts();
    var storage: [max_proxy_intercept_hosts][]const u8 = undefined;
    const configured = hosts.slices(&storage);

    try std.testing.expectEqual(default_proxy_intercept_hosts.len, configured.len);
    for (default_proxy_intercept_hosts, configured) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

pub const RuntimeSnapshot = struct {
    graphics_pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
    graphics_global_bytes: usize = core.graphics.max_image_bytes_global,
    history_path_bytes: [max_history_path_bytes]u8 = undefined,
    history_path_len: u16 = 0,
    proxy_enabled: bool = false,
    proxy_ca_dir_bytes: [max_proxy_path_bytes]u8 = undefined,
    proxy_ca_dir_len: u16 = 0,
    proxy_intercept_hosts: ProxyInterceptHosts = defaultProxyInterceptHosts(),
    proxy_capture_enabled: bool = false,
    proxy_capture_max_part_bytes: usize = core.proxy.default_capture_part_bytes,
    proxy_capture_max_exchange_bytes: usize = core.proxy.default_capture_exchange_bytes,
    proxy_capture_max_total_bytes: usize = core.proxy.default_capture_total_bytes,
    proxy_capture_join_timeout_ms: u32 = core.proxy.default_capture_join_timeout_ms,
    agent_descriptions: CommandSpec = .{},
    engine: CommandSpec = .{},
    engine_idle_timeout_ms: u32 = default_engine_idle_timeout_ms,
    agent_manifests: core.agent_manifest.Table = core.agent_manifest.builtin_table,
    history_filters: core.history_filter.Filters = .{},
    history_output_capture: bool = false,
    session_persist: bool = true,
    session_resume_agents: bool = true,
    session_path_bytes: [max_history_path_bytes]u8 = undefined,
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
    pub fn proxyInterceptHosts(snapshot: *const RuntimeSnapshot, storage: *[max_proxy_intercept_hosts][]const u8) []const []const u8 {
        return snapshot.proxy_intercept_hosts.slices(storage);
    }
};

pub const max_window_title_bytes = 128;

pub const Snapshot = struct {
    theme: theme.Theme = theme.default_theme,
    icon_theme: icons.Theme = .unicode,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    pane_gaps: bool = true,
    window_title_bytes: [max_window_title_bytes]u8 = undefined,
    window_title_len: u8 = 0,
    sound: SoundConfig = .{},
    notification_delivery: NotificationDelivery = .telar,
    history_show_agent_commands: bool = false,
    history_enter_runs: bool = false,
    history_match_fts: bool = false,
    theme_light: ?theme.Theme = null,
    theme_dark: ?theme.Theme = null,
    bars: bars.Configuration = .{},
    prefix: keybind.Key = keybind.default_prefix,
    input_escape_timeout_ns: u64 = keybind.default_escape_timeout_ns,
    input_sequence_timeout_ns: u64 = keybind.default_sequence_timeout_ns,
    bindings: [max_bindings]ConfiguredBinding = undefined,
    bindings_prefixed: [max_bindings]bool = undefined,
    binding_count: u16 = 0,
    runtime: RuntimeSnapshot = .{},
    plugins: [max_plugins]PluginSpec = undefined,
    plugin_count: u8 = 0,

    pub fn bindingSlice(snapshot: *const Snapshot) []const ConfiguredBinding {
        return snapshot.bindings[0..snapshot.binding_count];
    }

    /// The host window title template; empty leaves the host title alone.
    ///
    /// ```zig
    /// const template = snapshot.windowTitle();
    /// ```
    pub fn windowTitle(snapshot: *const Snapshot) []const u8 {
        return snapshot.window_title_bytes[0..snapshot.window_title_len];
    }
};

pub const CallbackContext = struct {
    sidebar_visible: bool,
    tab_count: u16,
    active_tab_index: u16,
    pane_count: u16,
    focused_pane_id: u64,
};

pub const BarTime = struct {
    unix_seconds: i64,
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};

pub const BarMetrics = struct {
    cpu_percent: u8,
    memory_used_decigib: u16,
    battery_percent: ?u8,
};

pub const BarCallbackContext = struct {
    client: CallbackContext,
    time: BarTime,
    metrics: ?BarMetrics,
    command_output: ?[]const u8 = null,
    /// Window title of the focused pane in the active tab, empty when unset.
    pane_title: []const u8 = "",
};

pub const BarInvocation = struct {
    reference: bars.CallbackRef,
    context: BarCallbackContext,
};

pub const EffectBatch = struct {
    items: [max_callback_effects]action.Action = undefined,
    len: u8 = 0,

    pub fn slice(batch: *const EffectBatch) []const action.Action {
        return batch.items[0..batch.len];
    }
};

pub const InputKeys = struct {
    items: [max_expression_keys]keybind.Key = undefined,
    len: u8 = 0,

    pub fn slice(keys: *const InputKeys) []const keybind.Key {
        return keys.items[0..keys.len];
    }
};

pub const InputPaste = struct {
    bytes: [max_expression_paste_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn slice(paste: *const InputPaste) []const u8 {
        return paste.bytes[0..paste.len];
    }
};

pub const InputDecision = union(enum) {
    consume,
    forward_binding: InputKeys,
    keys: InputKeys,
    paste: InputPaste,
};

pub const Limits = struct {
    memory: usize = default_memory_limit,
    instructions: u64 = default_load_instruction_limit,
    deadline_after_ns: u64 = 100 * std.time.ns_per_ms,
};
