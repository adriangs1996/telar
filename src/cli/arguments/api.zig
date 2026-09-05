//! Api command grammar and validated options.

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

pub const ApiOptions = struct {
    json: bool = false,

    pub fn parse(args: []const [*:0]const u8) !ApiOptions {
        if (args.len == 0 or !std.mem.eql(u8, std.mem.span(args[0]), "schema")) {
            return error.UnknownApiAction;
        }

        var options: ApiOptions = .{};
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, std.mem.span(arg), "--json")) {
                options.json = true;
            } else {
                return error.UnknownApiOption;
            }
        }

        return options;
    }
};
