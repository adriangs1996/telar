//! Hook command grammar and validated options.

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

pub const HookOptions = struct {
    agent: HookAgent,
    socket: ?[*:0]const u8 = null,

    pub fn parse(args: []const [*:0]const u8) !HookOptions {
        if (args.len == 0) {
            return error.MissingHookAgent;
        }
        var options: HookOptions = .{ .agent = try parseHookAgent(std.mem.span(args[0])) };
        var index: usize = 1;
        while (index < args.len) : (index += 2) {
            if (!std.mem.eql(u8, std.mem.span(args[index]), "--socket") or index + 1 >= args.len) {
                return error.UnknownHookOption;
            }
            options.socket = args[index + 1];
        }
        return options;
    }
};
