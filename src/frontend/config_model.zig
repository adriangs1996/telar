//! Validated configuration values shared by the Lua compiler and client.

const std = @import("std");
const core = @import("telar-core");
const action = @import("action.zig");
const keybind = @import("keybind.zig");
const kitty = @import("kitty.zig");
const theme = @import("theme.zig");

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

pub const RuntimeSnapshot = struct {
    graphics_pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
    graphics_global_bytes: usize = core.graphics.max_image_bytes_global,
    history_path_bytes: [max_history_path_bytes]u8 = undefined,
    history_path_len: u16 = 0,

    pub fn historyPath(snapshot: *const RuntimeSnapshot) ?[]const u8 {
        if (snapshot.history_path_len == 0) return null;
        return snapshot.history_path_bytes[0..snapshot.history_path_len];
    }
};

pub const Snapshot = struct {
    theme: theme.Theme = theme.default_theme,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    prefix: keybind.Key = keybind.default_prefix,
    input_escape_timeout_ns: u64 = keybind.default_escape_timeout_ns,
    input_sequence_timeout_ns: u64 = keybind.default_sequence_timeout_ns,
    bindings: [max_bindings]ConfiguredBinding = undefined,
    bindings_prefixed: [max_bindings]bool = undefined,
    binding_count: u16 = 0,
    bindings_configured: bool = false,
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
