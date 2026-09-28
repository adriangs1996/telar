//! A worktree whose checkout disappeared stays listed as `gone` until
//! someone forgets it. `forget-gone-worktrees` asks the runtime to forget
//! every such row; the checkout is already gone, so nothing on disk changes.
//! See `docs/flows/worktree-lifecycle.md`.

const std = @import("std");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");
const WorktreeRow = @import("WorktreeRow.zig");

/// Queues a `forget_worktree` for every gone row the replica lists whose
/// tabs are all closed, and returns how many it sent. A row forgotten meanwhile fails with
/// `worktree_not_found`, which nobody needs to hear about.
///
/// ```zig
/// const sent = try worktree_lifecycle.forgetGone(&client.model);
/// ```
pub fn forgetGone(model: *ClientModel) !usize {
    const snapshot = &model.workspace_list_snapshot;
    var sent: usize = 0;
    for (snapshot.worktrees[0..snapshot.worktree_count]) |*row| {
        // Forgetting closes the worktree's tabs; one with tabs open (a shell
        // left in the deleted directory) is the user's to close first.
        if (row.state != .gone or row.workspace != null) {
            continue;
        }

        const request_id = try model.request_lifecycle.nextId();
        model.request_lifecycle.tracker.add(request_id, .ignored) catch |err| switch (err) {
            // The rest waits for the next time the user asks.
            error.TooManyPendingRequests => break,
            else => return err,
        };
        errdefer _ = model.request_lifecycle.tracker.take(request_id);

        try model.to_runtime.pushEncoded(core.encodeForgetWorktree, core.ForgetWorktree{
            .request_id = request_id,
            .worktree = row.worktree,
        });
        sent += 1;
    }

    return sent;
}

fn testingRow(worktree: u64, state: core.WorktreeState) WorktreeRow {
    return .{
        .worktree = @enumFromInt(worktree),
        .source = @enumFromInt(1),
        .workspace = null,
        .state = state,
        .diff_added = 0,
        .diff_removed = 0,
        .diff_files = 0,
        .commits_ahead = 0,
        .command_state = .none,
        .command_exit = 0,
    };
}

test "only gone worktrees are forgotten" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    try model.to_runtime.reservePayloads(model.gpa);
    const snapshot = &model.workspace_list_snapshot;
    snapshot.worktrees[0] = testingRow(3, .active);
    snapshot.worktrees[1] = testingRow(4, .gone);
    snapshot.worktrees[2] = testingRow(5, .integrated);
    snapshot.worktrees[3] = testingRow(6, .gone);
    snapshot.worktree_count = 4;

    try std.testing.expectEqual(@as(usize, 2), try forgetGone(&model));
    try std.testing.expectEqual(@as(usize, 2), model.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(u8, 2), model.to_runtime.len);
}

test "a gone worktree whose tabs are still open is left for the user to close" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    try model.to_runtime.reservePayloads(model.gpa);
    var open = testingRow(3, .gone);
    open.workspace = @enumFromInt(9);
    model.workspace_list_snapshot.worktrees[0] = open;
    model.workspace_list_snapshot.worktrees[1] = testingRow(4, .gone);
    model.workspace_list_snapshot.worktree_count = 2;

    try std.testing.expectEqual(@as(usize, 1), try forgetGone(&model));
}

test "nothing is sent when no worktree is gone" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    try model.to_runtime.reservePayloads(model.gpa);
    model.workspace_list_snapshot.worktrees[0] = testingRow(3, .active);
    model.workspace_list_snapshot.worktree_count = 1;

    try std.testing.expectEqual(@as(usize, 0), try forgetGone(&model));
    try std.testing.expectEqual(@as(u8, 0), model.to_runtime.len);
}
