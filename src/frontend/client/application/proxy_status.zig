//! Application use case for reconciling runtime TLS interception state.

const std = @import("std");
const client_model = @import("../model.zig");

pub const ProxyStatusEffects = struct {
    context: *anyopaque,
    announce: *const fn (*anyopaque, client_model.ProxyStatusCommit) anyerror!void,
};

pub const ApplyProxyStatusHandler = struct {
    model: *client_model.Model,
    effects: ProxyStatusEffects,

    /// Commits a changed proxy state before announcing the transition.
    /// Repeated values produce neither a commit nor an announcement.
    ///
    /// ```zig
    /// const commit = try handler.execute(true) orelse return;
    /// ```
    pub fn execute(handler: *ApplyProxyStatusHandler, active: bool) !?client_model.ProxyStatusCommit {
        const commit = handler.model.reconcileProxyStatus(active) orelse return null;

        try handler.effects.announce(handler.effects.context, commit);
        return commit;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    commit: ?client_model.ProxyStatusCommit = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) ProxyStatusEffects {
        return .{ .context = capture, .announce = announce };
    }

    fn announce(context: *anyopaque, commit: client_model.ProxyStatusCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.commit = commit;
        capture.observed_commit = capture.model.proxyTlsActive() == commit.active and
            capture.model.version().proxy_status == commit.proxy_status_revision;

        if (capture.fail) {
            return error.AnnouncementFailed;
        }
    }
};

test "ApplyProxyStatusHandler commits before announcing each changed state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(false)) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const enabled = (try handler.execute(true)).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(enabled, capture.commit.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect((try handler.execute(true)) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    const disabled = (try handler.execute(false)).?;

    try std.testing.expect(!disabled.active);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 2 }, model.version());
}

test "ApplyProxyStatusHandler preserves a commit after announcement failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model, .fail = true };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.AnnouncementFailed, handler.execute(true));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 1 }, model.version());
}
