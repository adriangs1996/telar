//! Serializes configuration sections without access to client resources.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const Snapshot = @import("../../config/Snapshot.zig");
const Query = @import("../../config/ConfigurationQuery.zig");
const model = @import("../../config/model.zig");
pub const Section = enum { client, theme, gui, input, runtime, binding };

/// Writes one immutable configuration section into the bounded reply writer.
/// Example: `try config_queries.writeSection(snapshot, query, &writer);`
pub fn writeSection(snapshot: *const Snapshot, query: Query, writer: *std.Io.Writer) !void {
    switch (query.section) {
        .client => unreachable,
        .theme => try std.json.Stringify.value(.{ .base = snapshot.theme, .light = snapshot.theme_light, .dark = snapshot.theme_dark, .icons = snapshot.icon_theme, .sidebar_rendering = snapshot.sidebar_rendering }, .{}, writer),
        .gui => {
            const gui = &snapshot.gui;
            try std.json.Stringify.value(.{ .font = .{ .family = gui.font.family.name(), .size = gui.font.size, .line_height = gui.font.line_height, .letter_spacing = gui.font.letter_spacing, .thicken = gui.font.thicken, .thicken_strength = gui.font.thicken_strength }, .cursor = gui.cursor, .window = gui.window, .chrome = gui.chrome, .sidebar = gui.sidebar }, .{}, writer);
        },
        .input => try std.json.Stringify.value(.{ .prefix = snapshot.prefix, .escape_timeout_ns = snapshot.input_escape_timeout_ns, .sequence_timeout_ns = snapshot.input_sequence_timeout_ns, .binding_count = snapshot.binding_count }, .{}, writer),
        .binding => {
            if (query.index >= snapshot.binding_count) {
                return error.BindingNotFound;
            }

            const binding = &snapshot.bindings[query.index];
            try writer.print("{{\"index\":{d},\"prefixed\":{s},\"keys\":", .{ query.index, if (snapshot.bindings_prefixed[query.index]) "true" else "false" });
            try std.json.Stringify.value(binding.slice(), .{}, writer);
            try writer.writeAll(",\"action\":");
            try writeAction(binding.action, writer);
            try writer.writeByte('}');
        },
        .runtime => {
            const value = &snapshot.runtime;
            var hosts: [core.max_intercept_hosts][]const u8 = undefined;
            try std.json.Stringify.value(.{ .graphics_pane_bytes = value.graphics_pane_bytes, .graphics_global_bytes = value.graphics_global_bytes, .history_path = value.historyPath(), .history_output_capture = value.history_output_capture, .session_path = value.sessionPath(), .session_persist = value.session_persist, .session_resume_agents = value.session_resume_agents, .proxy_enabled = value.proxy_enabled, .proxy_ca_dir = value.proxyCaDir(), .proxy_intercept_hosts = value.proxyInterceptHosts(&hosts), .proxy_capture_enabled = value.proxy_capture_enabled, .proxy_capture_max_part_bytes = value.proxy_capture_max_part_bytes, .proxy_capture_max_exchange_bytes = value.proxy_capture_max_exchange_bytes, .proxy_capture_max_total_bytes = value.proxy_capture_max_total_bytes, .proxy_capture_join_timeout_ms = value.proxy_capture_join_timeout_ms, .engine_idle_timeout_ms = value.engine_idle_timeout_ms, .agent_manifest_count = value.agent_manifests.count }, .{}, writer);
        },
    }
}

fn writeAction(action: data.Action, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(@tagName(action), .{}, writer);
    try writer.writeAll(",\"value\":");
    switch (action) {
        .command_tab => |command| {
            var args: [32][]const u8 = undefined;
            for (0..command.argument_count) |index| {
                args[index] = command.argument(index);
            }

            try std.json.Stringify.value(.{ .label = command.label(), .argv = args[0..command.argument_count] }, .{}, writer);
        },
        .notification => |value| try std.json.Stringify.value(.{ .title = value.title(), .message = value.message(), .level = value.level, .duration_ms = value.duration_ms, .target = value.target }, .{}, writer),
        inline else => |value| {
            if (@TypeOf(value) == void) {
                try writer.writeAll("null");
            } else {
                try std.json.Stringify.value(value, .{}, writer);
            }
        },
    }

    try writer.writeByte('}');
}

test "configuration queries serialize occupied bindings and reject missing indices" {
    var snapshot: Snapshot = .{};
    snapshot.binding_count = 1;
    snapshot.bindings[0] = try model.ConfiguredBinding.init(&.{snapshot.prefix}, .{ .command_tab = try data.CommandTab.init(&.{ "echo", "ready" }, "test") });
    snapshot.bindings_prefixed[0] = true;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSection(&snapshot, .{ .section = .binding, .index = 0 }, &writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ready", parsed.value.object.get("action").?.object.get("value").?.object.get("argv").?.array.items[1].string);
    try std.testing.expectError(error.BindingNotFound, writeSection(&snapshot, .{ .section = .binding, .index = 1 }, &writer));
}
