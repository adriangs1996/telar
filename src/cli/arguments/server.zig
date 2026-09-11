//! Server command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;
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

pub const ServerOptions = @import("ServerOptions.zig");

pub fn parseMebibytes(value: [*:0]const u8) !usize {
    const mib = try std.fmt.parseUnsigned(usize, std.mem.span(value), 10);
    return std.math.mul(usize, mib, 1024 * 1024) catch error.InvalidGraphicsLimit;
}
