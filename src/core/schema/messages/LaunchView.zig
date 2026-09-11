const id = @import("../id.zig");
const types = @import("../types.zig");
const ArgumentIterator = @import("ArgumentIterator.zig");
const EnvironmentIterator = @import("EnvironmentIterator.zig");
const LaunchView = @This();

cwd: []const u8,
cwd_source: ?id.PaneId = null,
argument_count: u16,
encoded_arguments: []const u8,
environment_mode: types.EnvironmentMode,
environment_count: u16,
encoded_environment: []const u8,

pub fn arguments(launch: LaunchView) ArgumentIterator {
    return .{
        .decoder = .init(launch.encoded_arguments),
        .remaining = launch.argument_count,
    };
}

pub fn environment(launch: LaunchView) EnvironmentIterator {
    return .{
        .decoder = .init(launch.encoded_environment),
        .remaining = launch.environment_count,
    };
}
