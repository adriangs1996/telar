const Capture = @This();
const lua_config = @import("../../config/root.zig");
const source_namespace = @import("action_routing.zig");
const lua_action = @import("lua_action.zig");
const Effects = @import("ActionRoutingEffects.zig");
const std = @import("std");
events: [lua_config.max_expression_keys + 1]source_namespace.Event = undefined,
event_count: usize = 0,
native_control: source_namespace.Control = .continue_routing,
lua_outcome: lua_action.Outcome = .applied,
lua_command: ?lua_action.Command = null,
plugin_action: source_namespace.PluginAction = undefined,
keys: [lua_config.max_expression_keys]source_namespace.keybind.Key = undefined,
key_count: usize = 0,
paste_bytes: [32]u8 = undefined,
paste_len: usize = 0,
failure: source_namespace.Failure = .none,

pub fn port(capture: *Capture) Effects {
    return .{
        .context = capture,
        .native = native,
        .lua = lua,
        .plugin = plugin,
        .key = key,
        .paste = paste,
    };
}

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn native(raw_context: *anyopaque, value: source_namespace.Action) !source_namespace.Control {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = value;
    capture.record(.native);

    if (capture.failure == .native) {
        return error.NativeActionFailed;
    }

    return capture.native_control;
}

fn lua(raw_context: *anyopaque, command: lua_action.Command) !lua_action.Outcome {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.lua);
    capture.lua_command = command;

    if (capture.failure == .lua) {
        return error.LuaActionFailed;
    }

    return capture.lua_outcome;
}

fn plugin(raw_context: *anyopaque, requested: source_namespace.PluginAction) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.plugin);
    capture.plugin_action = requested;

    if (capture.failure == .plugin) {
        return error.PluginActionFailed;
    }
}

fn key(raw_context: *anyopaque, value: source_namespace.keybind.Key) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.key);
    capture.keys[capture.key_count] = value;
    capture.key_count += 1;

    if (capture.failure == .key) {
        return error.KeyRoutingFailed;
    }
}

fn paste(raw_context: *anyopaque, text: []const u8) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.paste);
    std.debug.assert(text.len <= capture.paste_bytes.len);
    @memcpy(capture.paste_bytes[0..text.len], text);
    capture.paste_len = text.len;

    if (capture.failure == .paste) {
        return error.PasteRoutingFailed;
    }
}
