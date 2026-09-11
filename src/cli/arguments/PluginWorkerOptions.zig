const CallbackContextType = @import("telar-client").CallbackContext;
const plugin_worker = @import("plugin_worker.zig");
const std = @import("std");
const PluginWorkerOptions = @This();

entry: [*:0]const u8,
action: [*:0]const u8,
context: CallbackContextType,

/// Example: `const options = try PluginWorkerOptions.parse(args);`.
pub fn parse(args: []const [*:0]const u8) !PluginWorkerOptions {
    if (args.len != 7) {
        return error.InvalidPluginWorkerArguments;
    }

    return .{
        .entry = args[0],
        .action = args[1],
        .context = .{
            .sidebar_visible = try plugin_worker.parseWorkerBool(args[2]),
            .tab_count = try std.fmt.parseUnsigned(u16, std.mem.span(args[3]), 10),
            .active_tab_index = try std.fmt.parseUnsigned(u16, std.mem.span(args[4]), 10),
            .pane_count = try std.fmt.parseUnsigned(u16, std.mem.span(args[5]), 10),
            .focused_pane_id = try std.fmt.parseUnsigned(u64, std.mem.span(args[6]), 10),
        },
    };
}
