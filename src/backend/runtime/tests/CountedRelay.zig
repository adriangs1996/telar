const FakeSessionType = @import("../../proxy/http/FakeSession.zig");
const SessionType = @import("../../proxy/Session.zig");
const FragmentType = @import("../../proxy/http/Fragment.zig");
const CountedRelay = @This();

fake: FakeSessionType,
writes: usize = 0,

/// Example: `const count = counted.read(.origin, buffer);`.
pub fn read(relay: *CountedRelay, side: SessionType.Side, bytes: []u8) ?usize {
    return relay.fake.read(side, bytes);
}

/// Example: `const forwarded = counted.writeAll(.child, bytes);`.
pub fn writeAll(relay: *CountedRelay, side: SessionType.Side, bytes: []const u8) bool {
    relay.writes += 1;
    return relay.fake.writeAll(side, bytes);
}

/// Example: `counted.observe(fragment);`.
pub fn observe(_: *CountedRelay, _: FragmentType) void {}
