const Fixture = @import("Fixture.zig");
const UnsupportedVoid = @This();

pub fn apply(_: *Fixture, _: anytype) !void {
    return error.UnsupportedTestEvent;
}
