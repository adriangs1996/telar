const plugin = @import("plugin.zig");
const CapabilityType = @import("telar-core").Capability;
const std = @import("std");
const PluginOptions = @This();

command: plugin.PluginCommand,
path: [*:0]const u8,
capabilities: [@typeInfo(CapabilityType).@"enum".fields.len]CapabilityType = undefined,
capability_count: u8 = 0,

/// Example: `const options = try PluginOptions.parse(args);`.
pub fn parse(args: []const [*:0]const u8) !PluginOptions {
    if (args.len < 2) {
        return error.MissingPluginArguments;
    }

    var plugin_options: PluginOptions = .{
        .command = if (std.mem.eql(u8, std.mem.span(args[0]), "inspect"))
            .inspect
        else if (std.mem.eql(u8, std.mem.span(args[0]), "install"))
            .install
        else if (std.mem.eql(u8, std.mem.span(args[0]), "trust"))
            .trust
        else
            return error.UnknownPluginAction,
        .path = args[1],
    };
    var plugin_arg: usize = 2;
    while (plugin_arg < args.len) {
        if (!std.mem.eql(u8, std.mem.span(args[plugin_arg]), "--capability") or
            plugin_arg + 1 >= args.len)
        {
            return error.InvalidPluginArguments;
        }
        if (plugin_options.capability_count == plugin_options.capabilities.len) {
            return error.TooManyPluginCapabilities;
        }

        plugin_options.capabilities[plugin_options.capability_count] =
            try CapabilityType.parse(std.mem.span(args[plugin_arg + 1]));
        plugin_options.capability_count += 1;
        plugin_arg += 2;
    }
    if (plugin_options.command != .trust and plugin_options.capability_count != 0) {
        return error.InvalidPluginArguments;
    }

    return plugin_options;
}
