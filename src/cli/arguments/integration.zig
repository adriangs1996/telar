//! Integration command grammar and validated options.

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

pub const IntegrationAction = enum { install, uninstall, status };

pub const IntegrationOptions = struct {
    action: IntegrationAction,
    agent: HookAgent,
    settings: ?[*:0]const u8 = null,

    pub fn parse(args: []const [*:0]const u8) !IntegrationOptions {
        if (args.len < 2) {
            return error.MissingIntegrationArguments;
        }

        const action_text = std.mem.span(args[0]);
        const action: IntegrationAction = if (std.mem.eql(u8, action_text, "install"))
            .install
        else if (std.mem.eql(u8, action_text, "uninstall"))
            .uninstall
        else if (std.mem.eql(u8, action_text, "status"))
            .status
        else
            return error.UnknownIntegrationAction;
        var options: IntegrationOptions = .{ .action = action, .agent = try parseHookAgent(std.mem.span(args[1])) };
        var index: usize = 2;
        while (index < args.len) : (index += 2) {
            if (!std.mem.eql(u8, std.mem.span(args[index]), "--settings") or index + 1 >= args.len) {
                return error.UnknownIntegrationOption;
            }
            options.settings = args[index + 1];
        }
        return options;
    }
};
