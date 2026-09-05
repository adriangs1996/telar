//! plugin-worker command grammar.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;

pub const PluginWorkerOptions = struct {
    entry: [*:0]const u8,
    action: [*:0]const u8,
    context: frontend.config.CallbackContext,

    /// Example: `const options = try PluginWorkerOptions.parse(args);`.
    pub fn parse(args: []const [*:0]const u8) !PluginWorkerOptions {
        if (args.len != 7) {
            return error.InvalidPluginWorkerArguments;
        }

        return .{
            .entry = args[0],
            .action = args[1],
            .context = .{
                .sidebar_visible = try parseWorkerBool(args[2]),
                .tab_count = try std.fmt.parseUnsigned(u16, std.mem.span(args[3]), 10),
                .active_tab_index = try std.fmt.parseUnsigned(u16, std.mem.span(args[4]), 10),
                .pane_count = try std.fmt.parseUnsigned(u16, std.mem.span(args[5]), 10),
                .focused_pane_id = try std.fmt.parseUnsigned(u64, std.mem.span(args[6]), 10),
            },
        };
    }
};

fn parseWorkerBool(value: [*:0]const u8) !bool {
    const text = std.mem.span(value);
    if (std.mem.eql(u8, text, "0")) {
        return false;
    }
    if (std.mem.eql(u8, text, "1")) {
        return true;
    }

    return error.InvalidPluginWorkerArguments;
}
