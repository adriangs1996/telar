//! Validated configuration values shared by the Lua compiler and client.

const std = @import("std");
const core = @import("telar-core");
const input = @import("../input/root.zig");
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
pub const max_agent_description_command_args = 32;
pub const max_agent_description_command_bytes = 4096;
pub const default_agent_description_timeout_ms: u32 = 15_000;
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

pub const AgentDescriptionCommand = struct {
    bytes: [max_agent_description_command_bytes]u8 = undefined,
    byte_len: u16 = 0,
    offsets: [max_agent_description_command_args]u16 = @splat(0),
    lengths: [max_agent_description_command_args]u16 = @splat(0),
    argument_count: u8 = 0,
    timeout_ms: u32 = default_agent_description_timeout_ms,

    pub fn enabled(command: *const AgentDescriptionCommand) bool {
        return command.argument_count != 0;
    }

    pub fn argument(command: *const AgentDescriptionCommand, index: usize) ?[]const u8 {
        if (index >= command.argument_count) return null;
        const start = command.offsets[index];
        return command.bytes[start .. start + command.lengths[index]];
    }

    pub fn arguments(
        command: *const AgentDescriptionCommand,
        storage: *[max_agent_description_command_args][]const u8,
    ) []const []const u8 {
        for (0..command.argument_count) |index| storage[index] = command.argument(index).?;
        return storage[0..command.argument_count];
    }
};

pub const RuntimeSnapshot = struct {
    graphics_pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
    graphics_global_bytes: usize = core.graphics.max_image_bytes_global,
    history_path_bytes: [max_history_path_bytes]u8 = undefined,
    history_path_len: u16 = 0,
    proxy_enabled: bool = false,
    proxy_ca_dir_bytes: [max_proxy_path_bytes]u8 = undefined,
    proxy_ca_dir_len: u16 = 0,
    agent_descriptions: AgentDescriptionCommand = .{},

    pub fn historyPath(snapshot: *const RuntimeSnapshot) ?[]const u8 {
        if (snapshot.history_path_len == 0) return null;
        return snapshot.history_path_bytes[0..snapshot.history_path_len];
    }

    pub fn proxyCaDir(snapshot: *const RuntimeSnapshot) ?[]const u8 {
        if (snapshot.proxy_ca_dir_len == 0) return null;
        return snapshot.proxy_ca_dir_bytes[0..snapshot.proxy_ca_dir_len];
    }
};

pub const Snapshot = struct {
    theme: theme.Theme = theme.default_theme,
    icon_theme: icons.Theme = .unicode,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    pane_gaps: bool = true,
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
};

pub const CallbackContext = struct {
    sidebar_visible: bool,
    tab_count: u16,
    active_tab_index: u16,
    pane_count: u16,
    focused_pane_id: u64,
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
