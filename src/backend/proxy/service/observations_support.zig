//! Observation pipeline and bounded delivery channel owned as one component.

const std = @import("std");
const Credential = @import("../Credential.zig");
const identity = @import("../identity.zig");
const Registry = @import("../Registry.zig");
const Observations = @import("Observations.zig");
const MiddlewareEvent = @import("../MiddlewareEvent.zig");

test "published observations traverse the owned channel exactly once" {
    const io = std.testing.io;
    var credential: Credential = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 2,
        .token = .{0x5a} ** identity.token_bytes,
    };
    defer std.crypto.secureZero(u8, &credential.token);
    var registry: Registry = .{};
    try registry.register(io, &credential);
    var observations: Observations = undefined;
    try observations.init(&registry);
    defer observations.close(io);
    var expected: MiddlewareEvent = .{
        .credential = credential,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 11,
        .observed_at_ms = 42,
    };
    defer std.crypto.secureZero(u8, &expected.credential.token);

    observations.pipeline().publish(io, expected);

    try std.testing.expectEqual(@as(u64, 1), observations.metrics().queued);
    var actual = try observations.receive(io);
    defer std.crypto.secureZero(u8, &actual.credential.token);
    try std.testing.expect(std.meta.eql(expected, actual));
    try std.testing.expectEqual(@as(u64, 0), observations.metrics().queued);
}
