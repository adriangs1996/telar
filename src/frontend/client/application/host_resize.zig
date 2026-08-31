//! Application use case for committing one resolved host resize.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    sync: *const fn (*anyopaque, client_model.HostResizeCommit) anyerror!void,
};

pub const ResizeHostHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits host geometry before synchronizing disposable resources.
    ///
    /// ```zig
    /// const commit = try handler.execute(size) orelse return;
    /// ```
    pub fn execute(handler: *ResizeHostHandler, size: schema.TerminalSize) !?client_model.HostResizeCommit {
        const commit = try handler.model.resizeHost(size) orelse return null;

        try handler.effects.sync(handler.effects.context, commit);
        return commit;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    commit: ?client_model.HostResizeCommit = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{ .context = capture, .sync = sync };
    }

    fn sync(context: *anyopaque, commit: client_model.HostResizeCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.commit = commit;
        capture.observed_commit = std.meta.eql(capture.model.hostSize(), commit.current) and
            capture.model.version().host == commit.host_revision;

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

    const commit = (try handler.execute(size)).?;

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

    try std.testing.expect((try handler.execute(model.hostSize())) == null);
    try std.testing.expectError(error.InvalidTerminalSize, handler.execute(.{
        .cols = 80,
        .rows = 0,
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

    try std.testing.expectError(error.HostResizeEffectsFailed, handler.execute(size));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(size, model.hostSize());
    try std.testing.expectEqual(client_model.Version{ .host = 1 }, model.version());
}
