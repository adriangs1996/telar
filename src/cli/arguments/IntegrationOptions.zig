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
        // Install and uninstall rename and delete by absolute path.
        if (!std.fs.path.isAbsolute(std.mem.span(args[index + 1]))) {
            return error.RelativeSettingsPath;
        }

        options.settings = args[index + 1];
    }
    return options;
}

test "integration settings paths must be absolute" {
    const options = try IntegrationOptions.parse(&.{ "install", "opencode", "--settings", "/home/me/.config/opencode/plugins/telar.ts" });
    try std.testing.expectEqualStrings("/home/me/.config/opencode/plugins/telar.ts", std.mem.span(options.settings.?));
    try std.testing.expectError(error.RelativeSettingsPath, IntegrationOptions.parse(&.{ "install", "opencode", "--settings", "plugins/telar.ts" }));
    try std.testing.expectError(error.RelativeSettingsPath, IntegrationOptions.parse(&.{ "uninstall", "pi", "--settings", "./telar.ts" }));
    try std.testing.expectError(error.RelativeSettingsPath, IntegrationOptions.parse(&.{ "install", "claude", "--settings", "" }));
    try std.testing.expectError(error.UnknownIntegrationOption, IntegrationOptions.parse(&.{ "install", "pi", "--settings" }));
}
