const Config = @This();
const std = @import("std");
const source_namespace = @import("main.zig");
filter: ?[]const u8 = null,
samples: usize = 12,
sample_ns: u64 = 40 * std.time.ns_per_ms,
json: bool = false,
list: bool = false,
enforce: bool = false,

fn parse(args: []const []const u8) !Config {
    var config: Config = .{};
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--filter")) {
            index += 1;
            if (index == args.len) {
                return error.MissingFilter;
            }
            config.filter = args[index];
        } else if (std.mem.eql(u8, arg, "--samples")) {
            index += 1;
            if (index == args.len) {
                return error.MissingSampleCount;
            }
            config.samples = try std.fmt.parseUnsigned(usize, args[index], 10);
            if (config.samples == 0 or config.samples > source_namespace.max_samples) {
                return error.InvalidSampleCount;
            }
        } else if (std.mem.eql(u8, arg, "--sample-ms")) {
            index += 1;
            if (index == args.len) {
                return error.MissingSampleDuration;
            }
            const milliseconds = try std.fmt.parseUnsigned(u64, args[index], 10);
            if (milliseconds == 0 or milliseconds > 5000) {
                return error.InvalidSampleDuration;
            }
            config.sample_ns = milliseconds * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            config.list = true;
        } else if (std.mem.eql(u8, arg, "--enforce")) {
            config.enforce = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }
    return config;
}

fn includes(config: Config, name: []const u8) bool {
    return config.filter == null or std.mem.find(u8, name, config.filter.?) != null;
}
