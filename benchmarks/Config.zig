const std = @import("std");
const main = @import("main.zig");
const InterveningWalk = @import("InterveningWalk.zig");
const PlacementBacking = @import("PlacementBacking.zig").PlacementBacking;
const PlacementMode = @import("PlacementMode.zig").PlacementMode;
const PlacementPolicy = @import("PlacementPolicy.zig");
const Config = @This();

filter: ?[]const u8 = null,
samples: usize = 12,
sample_ns: u64 = 40 * std.time.ns_per_ms,
json: bool = false,
list: bool = false,
enforce: bool = false,
storage: bool = false,
/// Where the idle-delivery fixtures' large allocations land. The defaults
/// leave every case as it runs without these options.
placement: PlacementMode = .baseline,
placement_backing: PlacementBacking = .debug,
placement_threshold: usize = PlacementPolicy.default_threshold,
placement_stride: usize = PlacementPolicy.default_stride,
/// Null spreads offsets over one page of the host.
placement_window: ?usize = null,
placement_report: bool = false,
/// Bytes of unrelated memory read before every idle flush; null runs the
/// flushes back to back.
intervening_walk: ?usize = null,

pub fn parse(args: []const []const u8) !Config {
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
            if (config.samples == 0 or config.samples > main.max_samples) {
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
        } else if (std.mem.eql(u8, arg, "--placement")) {
            index += 1;
            if (index == args.len) {
                return error.MissingPlacement;
            }
            config.placement = std.meta.stringToEnum(PlacementMode, args[index]) orelse return error.InvalidPlacement;
        } else if (std.mem.eql(u8, arg, "--placement-backing")) {
            index += 1;
            if (index == args.len) {
                return error.MissingPlacementBacking;
            }
            config.placement_backing = std.meta.stringToEnum(PlacementBacking, args[index]) orelse return error.InvalidPlacementBacking;
        } else if (std.mem.eql(u8, arg, "--placement-threshold")) {
            index += 1;
            if (index == args.len) {
                return error.MissingPlacementThreshold;
            }
            config.placement_threshold = std.fmt.parseUnsigned(usize, args[index], 10) catch return error.InvalidPlacementThreshold;
        } else if (std.mem.eql(u8, arg, "--placement-stride")) {
            index += 1;
            if (index == args.len) {
                return error.MissingPlacementStride;
            }
            config.placement_stride = std.fmt.parseUnsigned(usize, args[index], 10) catch return error.InvalidPlacementStride;
        } else if (std.mem.eql(u8, arg, "--placement-window")) {
            index += 1;
            if (index == args.len) {
                return error.MissingPlacementWindow;
            }
            config.placement_window = std.fmt.parseUnsigned(usize, args[index], 10) catch return error.InvalidPlacementWindow;
        } else if (std.mem.eql(u8, arg, "--placement-report")) {
            config.placement_report = true;
        } else if (std.mem.eql(u8, arg, "--intervening-walk")) {
            index += 1;
            if (index == args.len) {
                return error.MissingInterveningWalk;
            }
            const bytes = std.fmt.parseUnsigned(usize, args[index], 10) catch return error.InvalidInterveningWalk;
            if (bytes == 0 or bytes > InterveningWalk.max_bytes) {
                return error.InvalidInterveningWalk;
            }
            config.intervening_walk = bytes;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else if (std.mem.eql(u8, arg, "--storage")) {
            config.storage = true;
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

    try config.placementPolicy().validate();
    if ((config.placement_report or config.intervening_walk != null) and !config.json) {
        return error.ExperimentRecordsNeedJson;
    }

    return config;
}

/// The placement the idle-delivery fixtures are built under, with the
/// window resolved against this host.
///
/// ```zig
/// var placement = try PlacementAllocator.init(child, config.placementPolicy());
/// ```
pub fn placementPolicy(self: Config) PlacementPolicy {
    return .{
        .mode = self.placement,
        .threshold = self.placement_threshold,
        .stride = self.placement_stride,
        .window = self.placement_window orelse std.heap.pageSize(),
    };
}

pub fn includes(self: Config, name: []const u8) bool {
    return self.filter == null or std.mem.find(u8, name, self.filter.?) != null;
}
