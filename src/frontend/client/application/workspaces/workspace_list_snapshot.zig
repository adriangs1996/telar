//! Application use case for reconciling the runtime workspace-list replica.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");
const workspace_list = @import("../../../workspace/root.zig").workspace_list;

const schema = core.schema;

pub const Rejection = enum {
    too_many_workspaces,
    workspace_path_too_long,
    workspace_list_too_large,
    duplicate_workspace,
};

pub const Outcome = union(enum) {
    stale,
    rejected: Rejection,
    applied: client_model.WorkspaceListCommit,
};

pub const ReconcileWorkspaceListHandler = struct {
    model: *client_model.Model,

    /// Classifies one decoded domain snapshot without deciding presentation.
    ///
    /// ```zig
    /// const outcome = try handler.execute(snapshot);
    /// ```
    pub fn execute(handler: *ReconcileWorkspaceListHandler, snapshot: workspace_list.SnapshotInput) !Outcome {
        const commit = handler.model.reconcileWorkspaceList(snapshot) catch |err| {
            const rejection = classifyRejection(err) orelse return err;

            return .{ .rejected = rejection };
        };

        return if (commit) |value| .{ .applied = value } else .stale;
    }
};

fn classifyRejection(err: anyerror) ?Rejection {
    return switch (err) {
        error.TooManyWorkspaces => .too_many_workspaces,
        error.WorkspacePathTooLong => .workspace_path_too_long,
        error.WorkspaceListTooLarge => .workspace_list_too_large,
        error.DuplicateWorkspace => .duplicate_workspace,
        else => null,
    };
}

test "ReconcileWorkspaceListHandler commits only newer runtime state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileWorkspaceListHandler = .{ .model = &model };
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    const commit = (try handler.execute(.{ .revision = 7, .entries = &entries })).applied;

    try std.testing.expectEqual(@as(u64, 7), commit.runtime_revision);
    try std.testing.expectEqual(@as(usize, 2), commit.count);
    try std.testing.expectEqual(@as(u64, 1), commit.workspace_list_revision);
    try std.testing.expect(model.knowsWorkspace(@enumFromInt(2)));
    try std.testing.expectEqual(client_model.Version{ .workspace_list = 1 }, model.version());
    try std.testing.expect(try handler.execute(.{ .revision = 7, .entries = &entries }) == .stale);
    try std.testing.expectEqual(client_model.Version{ .workspace_list = 1 }, model.version());
}

test "ReconcileWorkspaceListHandler classifies every bounded replacement rejection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileWorkspaceListHandler = .{ .model = &model };
    const baseline_entries = [_]workspace_list.EntryInput{.{
        .workspace = @enumFromInt(9),
        .name = "baseline",
        .path = "/baseline",
        .tab_count = 1,
    }};
    _ = try handler.execute(.{ .revision = 1, .entries = &baseline_entries });
    const too_many_entries: [workspace_list.max_entries + 1]workspace_list.EntryInput = @splat(.{
        .workspace = @enumFromInt(1),
        .name = "workspace",
        .path = "/work",
        .tab_count = 1,
    });

    const too_many = try handler.execute(.{ .revision = 2, .entries = &too_many_entries });

    try std.testing.expectEqual(Rejection.too_many_workspaces, too_many.rejected);

    const oversized_path: [schema.max_cwd_bytes + 1]u8 = @splat('x');
    const oversized_path_entry = [_]workspace_list.EntryInput{.{
        .workspace = @enumFromInt(1),
        .name = "workspace",
        .path = &oversized_path,
        .tab_count = 1,
    }};
    const path_too_long = try handler.execute(.{ .revision = 2, .entries = &oversized_path_entry });

    try std.testing.expectEqual(Rejection.workspace_path_too_long, path_too_long.rejected);

    const maximum_path: [schema.max_cwd_bytes]u8 = @splat('y');
    const oversized_list_entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "one", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "two", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "three", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(4), .name = "four", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(5), .name = "five", .path = &maximum_path, .tab_count = 1 },
    };
    const list_too_large = try handler.execute(.{ .revision = 2, .entries = &oversized_list_entries });

    try std.testing.expectEqual(Rejection.workspace_list_too_large, list_too_large.rejected);

    const duplicate_entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(1), .name = "duplicate", .path = "/duplicate", .tab_count = 1 },
    };
    const duplicate = try handler.execute(.{ .revision = 2, .entries = &duplicate_entries });

    try std.testing.expectEqual(Rejection.duplicate_workspace, duplicate.rejected);
    try std.testing.expect(classifyRejection(error.UnexpectedWorkspaceListFailure) == null);
    try std.testing.expectEqual(client_model.Version{ .workspace_list = 1 }, model.version());
    try std.testing.expectEqual(@as(u64, 1), model.workspaceListSnapshot().revision);
    try std.testing.expectEqualStrings("/baseline", model.workspaceListSnapshot().pathAt(0));
}
