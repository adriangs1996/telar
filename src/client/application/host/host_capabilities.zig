//! Application use cases for host-capability presentation capability observations.

const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const HostCapabilitiesEffectsCapture = @import("HostCapabilitiesEffectsCapture.zig");
const Handler = @import("HostCapabilitiesHandler.zig");
const VersionType = @import("../../model/Version.zig");

test "Handler commits an observation before synchronizing resources" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: HostCapabilitiesEffectsCapture = .{ .model = &model };
    var handler: Handler = .{
        .model = &model,
        .effects = capture.port(),
    };

    const commit = (try handler.observe(.{ .images = .supported })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(
        VersionType{ .host_capabilities = 1 },
        model.version(),
    );
    try std.testing.expectEqual(
        commit.capabilities.?.host_capabilities_revision,
        model.version().host_capabilities,
    );
}

test "Handler suppresses repeated presentation capability observations" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: HostCapabilitiesEffectsCapture = .{ .model = &model };
    var handler: Handler = .{
        .model = &model,
        .effects = capture.port(),
    };

    _ = try handler.observe(.{ .images = .supported });
    _ = try handler.reconcile(model.hostCapabilities().withObservation(.{ .pointer_pixels = .unsupported }));
    const calls = capture.calls;
    const version = model.version();

    try std.testing.expect((try handler.observe(.{ .images = .supported })) == null);
    try std.testing.expect((try handler.reconcile(model.hostCapabilities().withObservation(.{ .pointer_pixels = .unsupported }))) == null);
    try std.testing.expectEqual(calls, capture.calls);
    try std.testing.expectEqualDeep(version, model.version());
}

test "Handler retains a capability commit after effect failure" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: HostCapabilitiesEffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: Handler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(
        error.HostCapabilityEffectsFailed,
        handler.observe(.{ .pointer_pixels = .supported }),
    );

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(
        VersionType{ .host_capabilities = 1 },
        model.version(),
    );
    try std.testing.expectEqual(
        @as(@TypeOf(model.hostCapabilities().pointer_pixels), .supported),
        model.hostCapabilities().pointer_pixels,
    );
}
