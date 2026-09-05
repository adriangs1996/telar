//! tap-worker command grammar.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;

pub const TapWorkerOptions = struct {
    entry: [*:0]const u8,

    /// Example: `const options = try TapWorkerOptions.parse(args);`.
    pub fn parse(args: []const [*:0]const u8) !TapWorkerOptions {
        if (args.len != 1) {
            return error.InvalidTapWorkerArguments;
        }

        return .{ .entry = args[0] };
    }
};
