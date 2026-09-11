const HookOptions = @This();
const source_namespace = @import("hook.zig");
const std = @import("std");
agent: source_namespace.HookAgent,
socket: ?[*:0]const u8 = null,

pub fn parse(args: []const [*:0]const u8) !HookOptions {
    if (args.len == 0) {
        return error.MissingHookAgent;
    }
    var options: HookOptions = .{ .agent = try source_namespace.parseHookAgent(std.mem.span(args[0])) };
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (!std.mem.eql(u8, std.mem.span(args[index]), "--socket") or index + 1 >= args.len) {
            return error.UnknownHookOption;
        }
        options.socket = args[index + 1];
    }
    return options;
}
