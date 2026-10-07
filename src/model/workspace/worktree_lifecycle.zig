//! A worktree whose checkout disappeared stays listed as `gone` until
//! someone forgets it. `forget-gone-worktrees` asks the runtime to forget
//! every such row; the checkout is already gone, so nothing on disk changes.

const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

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
