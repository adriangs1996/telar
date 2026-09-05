//! Server command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;
const values = @import("values.zig");
const Target = values.Target;
const max_wait_timeout_seconds = values.max_wait_timeout_seconds;
const default_wait_timeout_seconds = values.default_wait_timeout_seconds;
const HookAgent = values.HookAgent;
const parseHookAgent = values.parseHookAgent;
const parseWaitStatus = values.parseWaitStatus;
const parseTimeoutSeconds = values.parseTimeoutSeconds;
const parseLineCount = values.parseLineCount;
const parseTextSource = values.parseTextSource;

pub const ServerMode = enum {
    foreground,
    background_launcher,
    daemonized,
};

pub const ServerAction = enum {
    run,
    stop,
    /// Ensure the runtime is running and print its socket path. Used by
    /// `telar --remote` over SSH to discover the remote endpoint.
    endpoint,
};

pub const ServerOptions = struct {
    action: ServerAction = .run,
    mode: ServerMode = .foreground,
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

                options.graphics.pane_bytes = try parseMebibytes(value);
                options.graphics_pane_set = true;
            } else if (std.mem.eql(u8, arg, "--graphics-global-mib")) {
                const value = try cursor.require(error.MissingGraphicsGlobalLimit);

                options.graphics.global_bytes = try parseMebibytes(value);
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
};

fn parseMebibytes(value: [*:0]const u8) !usize {
    const mib = try std.fmt.parseUnsigned(usize, std.mem.span(value), 10);
    return std.math.mul(usize, mib, 1024 * 1024) catch error.InvalidGraphicsLimit;
}
