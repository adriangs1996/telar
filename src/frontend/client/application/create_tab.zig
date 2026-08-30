//! Application use case for applying one runtime-confirmed tab creation.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const CreateTab = client_model.NewTab;

pub const CreationEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, client_model.TabCreation) anyerror!void,
};

pub const CreateTabHandler = struct {
    model: *client_model.Model,
    effects: CreationEffects,

    /// Commits the canonical tab before synchronizing client resources.
    /// Model failures have no effects; effect failures preserve the commit.
    ///
    /// ```zig
    /// const creation = try handler.execute(command);
    /// ```
    pub fn execute(handler: *CreateTabHandler, command: CreateTab) !client_model.TabCreation {
        const creation = try handler.model.createTab(command);
        try handler.effects.apply(handler.effects.context, creation);

        return creation;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    expected: schema.TabLocation,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) CreationEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, creation: client_model.TabCreation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const version = capture.model.version();
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
            capture.model.workspace.count == 2 and
            version.tabs == 1 and
            version.active_tab == 1 and
            std.meta.eql(creation.created, capture.expected);

        if (capture.fail) {
            return error.CreationSyncFailed;
        }
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    first: schema.TabLocation,
    second: schema.TabLocation,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const first: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const second: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn command(testing: *const TestingModel) CreateTab {
        return .{
            .created = .{
                .location = testing.second,
                .position = 1,
                .label = "logs",
                .root_pane_id = @enumFromInt(2),
            },
            .size = .{ .cols = 20, .rows = 5 },
        };
    }
};

test "CreateTabHandler commits before synchronizing client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: CreateTabHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const creation = try handler.execute(testing.command());

    try std.testing.expectEqualDeep(testing.first, creation.previous);
    try std.testing.expectEqualDeep(testing.second, creation.created);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "CreateTabHandler rejects model failures before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: CreateTabHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };
    var command = testing.command();
    command.created.location.workspace = .{ .workspace = @enumFromInt(9) };

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(command));

    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.count);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "CreateTabHandler preserves a committed creation after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected = testing.second,
        .fail = true,
    };
    var handler: CreateTabHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.CreationSyncFailed, handler.execute(testing.command()));

    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
    try std.testing.expect(effects.observed_commit);
}
