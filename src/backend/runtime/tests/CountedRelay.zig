const CountedRelay = @This();

const Fake = @import("../../proxy/http/test_support.zig").FakeSession;
const Side = @import("../../proxy/tls.zig").Session.Side;
fake: Fake,
writes: usize = 0,

/// Example: `const count = counted.read(.origin, buffer);`.
pub fn read(relay: *CountedRelay, side: Side, bytes: []u8) ?usize {
    return relay.fake.read(side, bytes);
}

/// Example: `const forwarded = counted.writeAll(.child, bytes);`.
pub fn writeAll(relay: *CountedRelay, side: Side, bytes: []const u8) bool {
    relay.writes += 1;
    return relay.fake.writeAll(side, bytes);
}

/// Example: `counted.observe(fragment);`.
pub fn observe(_: *CountedRelay, _: @import("../../proxy/http/body.zig").Fragment) void {}
