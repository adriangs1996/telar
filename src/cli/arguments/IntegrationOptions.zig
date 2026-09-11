const integration = @import("integration.zig");
const values = @import("values.zig");
const std = @import("std");
const IntegrationOptions = @This();

action: integration.IntegrationAction,
agent: values.HookAgent,
settings: ?[*:0]const u8 = null,

pub fn parse(args: []const [*:0]const u8) !IntegrationOptions {
    if (args.len < 2) {
        return error.MissingIntegrationArguments;
    }

    const action_text = std.mem.span(args[0]);
    const action: integration.IntegrationAction = if (std.mem.eql(u8, action_text, "install"))
        .install
    else if (std.mem.eql(u8, action_text, "uninstall"))
        .uninstall
    else if (std.mem.eql(u8, action_text, "status"))
        .status
    else
        return error.UnknownIntegrationAction;
    var options: IntegrationOptions = .{ .action = action, .agent = try values.parseHookAgent(std.mem.span(args[1])) };
    var index: usize = 2;
    while (index < args.len) : (index += 2) {
        if (!std.mem.eql(u8, std.mem.span(args[index]), "--settings") or index + 1 >= args.len) {
            return error.UnknownIntegrationOption;
        }
        options.settings = args[index + 1];
    }
    return options;
}
