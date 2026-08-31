//! Application use case for adopting one client configuration generation.

const std = @import("std");
const client_model = @import("../model.zig");

pub const Effects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, client_model.ConfigurationCommit) anyerror!void,
};

pub const ApplyConfigHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits semantic configuration before swapping concrete client resources.
    ///
    /// ```zig
    /// const commit = try handler.execute(input);
    /// ```
    pub fn execute(handler: *ApplyConfigHandler, input: client_model.ConfigurationInput) !client_model.ConfigurationCommit {
        const commit = try handler.model.applyConfiguration(input);

        try handler.effects.apply(handler.effects.context, commit);
        return commit;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    commit: ?client_model.ConfigurationCommit = null,
    fail: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, commit: client_model.ConfigurationCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.commit = commit;
        capture.observed_commit = capture.model.configurationGeneration() == commit.generation and
            capture.model.version().configuration == commit.configuration_revision and
            capture.model.version().panes == commit.panes_revision;

        if (capture.fail) {
            return error.ConfigEffectsFailed;
        }
    }
};

test "ApplyConfigHandler commits before applying concrete client resources" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyConfigHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    const commit = try handler.execute(.{
        .generation = 2,
        .sidebar_visible = false,
        .pane_gaps = false,
    });

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(commit, capture.commit.?);
    try std.testing.expect(!model.sidebarVisible());
    try std.testing.expect(!model.paneGaps());
}

test "ApplyConfigHandler retains the semantic commit after effect failure" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();
    var capture: EffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: ApplyConfigHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ConfigEffectsFailed, handler.execute(.{
        .generation = 2,
        .sidebar_visible = false,
        .pane_gaps = false,
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(u64, 2), model.configurationGeneration());
    try std.testing.expectEqual(client_model.Version{
        .configuration = 1,
        .panes = 1,
        .chrome = 1,
    }, model.version());
}
