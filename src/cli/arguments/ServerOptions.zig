const ServerOptions = @This();
const source_namespace = @import("server.zig");
const backend = @import("telar-backend");
const Cursor = @import("cursor_support.zig").Cursor;
const std = @import("std");
action: source_namespace.ServerAction = .run,
mode: source_namespace.ServerMode = .foreground,
socket: ?[*:0]const u8 = null,
graphics: backend.runtime.GraphicsLimits = .{},
graphics_pane_set: bool = false,
graphics_global_set: bool = false,
config: ?[*:0]const u8 = null,
no_config: bool = false,
profile: ?[*:0]const u8 = null,
/// Set the previous session checkpoint aside instead of restoring it.
fresh: bool = false,

pub fn parse(args: []const [*:0]const u8) !ServerOptions {
    var options: ServerOptions = .{};
    var action_explicit = false;
    const index: usize = 0;
    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "stop")) {
            if (action_explicit) {
                return error.DuplicateServerAction;
            }

            options.action = .stop;
            action_explicit = true;
        } else if (std.mem.eql(u8, arg, "endpoint")) {
            if (action_explicit) {
                return error.DuplicateServerAction;
            }

            options.action = .endpoint;
            action_explicit = true;
        } else if (std.mem.eql(u8, arg, "--background")) {
            if (options.mode != .foreground) {
                return error.ConflictingServerModes;
            }

            options.mode = .background_launcher;
        } else if (std.mem.eql(u8, arg, "--daemonized")) {
            if (options.mode != .foreground) {
                return error.ConflictingServerModes;
            }

            options.mode = .daemonized;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            if (options.socket != null) {
                return error.DuplicateSocketOption;
            }
            const value = try cursor.require(error.MissingSocketPath);

            options.socket = value;
        } else if (std.mem.eql(u8, arg, "--graphics-pane-mib")) {
            const value = try cursor.require(error.MissingGraphicsPaneLimit);

            options.graphics.pane_bytes = try source_namespace.parseMebibytes(value);
            options.graphics_pane_set = true;
        } else if (std.mem.eql(u8, arg, "--graphics-global-mib")) {
            const value = try cursor.require(error.MissingGraphicsGlobalLimit);

            options.graphics.global_bytes = try source_namespace.parseMebibytes(value);
            options.graphics_global_set = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (options.config != null or options.no_config) {
                return error.DuplicateConfigOption;
            }
            const value = try cursor.require(error.MissingConfigPath);

            options.config = value;
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            if (options.config != null or options.no_config) {
                return error.DuplicateConfigOption;
            }

            options.no_config = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            if (options.profile != null) {
                return error.DuplicateProfileOption;
            }
            const value = try cursor.require(error.MissingProfileName);

            options.profile = value;
        } else if (std.mem.eql(u8, arg, "--fresh")) {
            if (options.fresh) {
                return error.DuplicateFreshOption;
            }

            options.fresh = true;
        } else {
            return error.UnknownServerOption;
        }
    }
    if (options.action == .stop and options.mode != .foreground) {
        return error.ConflictingServerAction;
    }
    if (options.fresh and options.action != .run) {
        return error.FreshRequiresRun;
    }
    if (options.no_config and options.profile != null) {
        return error.ProfileWithoutConfig;
    }

    try options.graphics.validate();
    return options;
}
