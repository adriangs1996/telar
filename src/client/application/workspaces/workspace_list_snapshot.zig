//! Application use case for reconciling the runtime workspace-list replica.

const WorkspaceListCommitType = @import("../../model/WorkspaceListCommit.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const ReconcileWorkspaceListHandler = @import("ReconcileWorkspaceListHandler.zig");
const EntryInputType = @import("../../workspace/EntryInput.zig");
const VersionType = @import("../../model/Version.zig");
const max_workspace_list_entries = @import("telar-core").max_workspace_list_entries;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;

pub const Rejection = enum {
    too_many_workspaces,
    workspace_path_too_long,
    workspace_list_too_large,
    duplicate_workspace,
};

pub const Outcome = union(enum) {
    stale,
    rejected: Rejection,
    applied: WorkspaceListCommitType,
};

pub fn classifyRejection(err: anyerror) ?Rejection {
    return switch (err) {
        error.TooManyWorkspaces => .too_many_workspaces,
        error.WorkspacePathTooLong => .workspace_path_too_long,
        error.WorkspaceListTooLarge => .workspace_list_too_large,
        error.DuplicateWorkspace => .duplicate_workspace,
        else => null,
    };
}

test "ReconcileWorkspaceListHandler commits only newer runtime state" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileWorkspaceListHandler = .{ .model = &model };
    const entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    const commit = (try handler.execute(.{ .revision = 7, .entries = &entries })).applied;

    try std.testing.expectEqual(@as(u64, 7), commit.runtime_revision);
    try std.testing.expectEqual(@as(usize, 2), commit.count);
    try std.testing.expectEqual(@as(u64, 1), commit.workspace_list_revision);
    try std.testing.expect(model.knowsWorkspace(@enumFromInt(2)));
    try std.testing.expectEqual(VersionType{ .workspace_list = 1 }, model.version());
    try std.testing.expect(try handler.execute(.{ .revision = 7, .entries = &entries }) == .stale);
    try std.testing.expectEqual(VersionType{ .workspace_list = 1 }, model.version());
}

test "ReconcileWorkspaceListHandler classifies every bounded replacement rejection" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ReconcileWorkspaceListHandler = .{ .model = &model };
    const baseline_entries = [_]EntryInputType{.{
        .workspace = @enumFromInt(9),
        .name = "baseline",
        .path = "/baseline",
        .tab_count = 1,
    }};
    _ = try handler.execute(.{ .revision = 1, .entries = &baseline_entries });
    const too_many_entries: [max_workspace_list_entries + 1]EntryInputType = @splat(.{
        .workspace = @enumFromInt(1),
        .name = "workspace",
        .path = "/work",
        .tab_count = 1,
    });

    const too_many = try handler.execute(.{ .revision = 2, .entries = &too_many_entries });

    try std.testing.expectEqual(Rejection.too_many_workspaces, too_many.rejected);

    const oversized_path: [max_cwd_bytes_module + 1]u8 = @splat('x');
    const oversized_path_entry = [_]EntryInputType{.{
        .workspace = @enumFromInt(1),
        .name = "workspace",
        .path = &oversized_path,
        .tab_count = 1,
    }};
    const path_too_long = try handler.execute(.{ .revision = 2, .entries = &oversized_path_entry });

    try std.testing.expectEqual(Rejection.workspace_path_too_long, path_too_long.rejected);

    const maximum_path: [max_cwd_bytes_module]u8 = @splat('y');
    const oversized_list_entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "one", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "two", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "three", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(4), .name = "four", .path = &maximum_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(5), .name = "five", .path = &maximum_path, .tab_count = 1 },
    };
    const list_too_large = try handler.execute(.{ .revision = 2, .entries = &oversized_list_entries });

    try std.testing.expectEqual(Rejection.workspace_list_too_large, list_too_large.rejected);

    const duplicate_entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(1), .name = "duplicate", .path = "/duplicate", .tab_count = 1 },
    };
    const duplicate = try handler.execute(.{ .revision = 2, .entries = &duplicate_entries });

    try std.testing.expectEqual(Rejection.duplicate_workspace, duplicate.rejected);
    try std.testing.expect(classifyRejection(error.UnexpectedWorkspaceListFailure) == null);
    try std.testing.expectEqual(VersionType{ .workspace_list = 1 }, model.version());
    try std.testing.expectEqual(@as(u64, 1), model.workspaceListSnapshot().revision);
    try std.testing.expectEqualStrings("/baseline", model.workspaceListSnapshot().pathAt(0));
}
