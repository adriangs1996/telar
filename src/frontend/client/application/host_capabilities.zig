//! Application use cases for host-capability observations and expiry.

const std = @import("std");
const client_model = @import("../model.zig");

pub const Effects = struct {
    context: *anyopaque,
    sync: *const fn (*anyopaque, client_model.HostCommit) anyerror!void,
};

pub const Handler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits one semantic host response before synchronizing resources.
    ///
    /// ```zig
    /// const commit = try handler.observe(observation) orelse return;
    /// ```
    pub fn observe(handler: *Handler, observation: client_model.HostCapabilityObservation) !?client_model.HostCommit {
        const commit = try handler.model.observeHostCapability(observation) orelse return null;

        try handler.effects.sync(handler.effects.context, commit);
        return commit;
    }

    /// Settles unanswered probes before synchronizing their fallback resources.
    ///
    /// ```zig
    /// const commit = try handler.expire() orelse return;
    /// ```
    pub fn expire(handler: *Handler) !?client_model.HostCommit {
        const commit = try handler.model.expireHostCapabilities() orelse return null;

        try handler.effects.sync(handler.effects.context, commit);
        return commit;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{ .context = capture, .sync = sync };
    }

    fn sync(raw_context: *anyopaque, commit: client_model.HostCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
        const capabilities = commit.capabilities.?;
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(
            capture.model.hostCapabilities(),
            capabilities.current,
        ) and capture.model.version().host_capabilities ==
            capabilities.host_capabilities_revision;

        if (capture.fail) {
            return error.HostCapabilityEffectsFailed;
        }
    }
};

test "Handler commits an observation before synchronizing resources" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: Handler = .{
        .model = &model,
        .effects = capture.port(),
    };

    const commit = (try handler.observe(.{ .kitty_graphics = .supported })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(
        client_model.Version{ .host_capabilities = 1 },
        model.version(),
    );
    try std.testing.expectEqual(
        commit.capabilities.?.host_capabilities_revision,
        model.version().host_capabilities,
    );
}

test "Handler suppresses repeated observations and expiry" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: Handler = .{
        .model = &model,
        .effects = capture.port(),
    };

    _ = try handler.observe(.{ .kitty_graphics = .supported });
    _ = try handler.expire();
    const calls = capture.calls;
    const version = model.version();

    try std.testing.expect((try handler.observe(.{ .kitty_graphics = .supported })) == null);
    try std.testing.expect((try handler.expire()) == null);
    try std.testing.expectEqual(calls, capture.calls);
    try std.testing.expectEqualDeep(version, model.version());
}

test "Handler retains a capability commit after effect failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: Handler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(
        error.HostCapabilityEffectsFailed,
        handler.observe(.{ .mouse_pixels = .supported }),
    );

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(
        client_model.Version{ .host_capabilities = 1 },
        model.version(),
    );
    try std.testing.expectEqual(
        @as(@TypeOf(model.hostCapabilities().mouse_pixels), .supported),
        model.hostCapabilities().mouse_pixels,
    );
}
