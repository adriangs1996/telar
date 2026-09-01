//! Application use case for committing one resolved host resize.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.HostCommit) anyerror!void,
};

pub const ResizeHostHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits one measured host state before synchronizing disposable resources.
    ///
    /// ```zig
    /// const commit = try handler.execute(update) orelse return;
    /// ```
    pub fn execute(handler: *ResizeHostHandler, update: client_model.HostUpdate) !?client_model.HostCommit {
        const commit = try handler.model.reconcileHost(update) orelse return null;

        try handler.effects.deliver(handler.effects.context, commit);
        return commit;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    commit: ?client_model.HostCommit = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, commit: client_model.HostCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.commit = commit;
        const resize_observed = if (commit.resize) |resize|
            std.meta.eql(capture.model.hostSize(), resize.current) and
                capture.model.version().host == resize.host_revision
        else
            true;
        const capabilities_observed = if (commit.capabilities) |capabilities|
            std.meta.eql(capture.model.hostCapabilities(), capabilities.current) and
                capture.model.version().host_capabilities ==
                    capabilities.host_capabilities_revision
        else
            true;
        capture.observed_commit = resize_observed and capabilities_observed;

        if (capture.fail) {
            return error.HostResizeEffectsFailed;
        }
    }
};

test "ResizeHostHandler commits before synchronizing client resources" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ResizeHostHandler = .{
        .model = &model,
        .effects = capture.port(),
    };
    const size: schema.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var capabilities = model.hostCapabilities();
    capabilities.window_width_px = 1000;
    capabilities.window_height_px = 600;

    const commit = (try handler.execute(.{
        .capabilities = capabilities,
        .size = size,
    })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(commit, capture.commit.?);
}

test "ResizeHostHandler suppresses repeated and invalid geometry" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ResizeHostHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{
        .capabilities = model.hostCapabilities(),
        .size = model.hostSize(),
    })) == null);
    try std.testing.expectError(error.InvalidTerminalSize, handler.execute(.{
        .capabilities = model.hostCapabilities(),
        .size = .{ .cols = 80, .rows = 0 },
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "ResizeHostHandler retains the model commit after effect failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: ResizeHostHandler = .{
        .model = &model,
        .effects = capture.port(),
    };
    const size: schema.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var capabilities = model.hostCapabilities();
    capabilities.window_width_px = 1000;
    capabilities.window_height_px = 600;

    try std.testing.expectError(error.HostResizeEffectsFailed, handler.execute(.{
        .capabilities = capabilities,
        .size = size,
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(size, model.hostSize());
    try std.testing.expectEqual(@as(u32, 1000), model.hostCapabilities().window_width_px);
    try std.testing.expectEqual(client_model.Version{
        .host = 1,
        .host_capabilities = 1,
    }, model.version());
}
