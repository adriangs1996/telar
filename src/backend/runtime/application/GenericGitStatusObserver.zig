const std = @import("std");
const worker = @import("../resources/git_probe.zig");
const JobType = @import("../resources/Job.zig");
const CompletionType = @import("../resources/Completion.zig");

/// Binds Git observation to runtime scheduling, not workspace representation.
/// Example: `const GitObserver = Observer(RuntimeModel);`.
pub fn Type(comptime RuntimeModel: type) type {
    return struct {
        /// Starts one due probe, rolling back its reservation on scheduling failure.
        /// Example: `GitObserver.tick(model);`.
        pub fn tick(model: *RuntimeModel) void {
            var repository = model.workspaceRepository();
            const request = repository.reserveGitProbe(.{
                .now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
                .interval_ms = worker.probe_interval_ms,
            }) orelse return;

            model.select.concurrent(.git_status, worker.probe, .{JobType{
                .io = model.io,
                .request = request,
            }}) catch repository.cancelGitProbe(request.workspace);
        }

        /// Applies only the outstanding observation and publishes visible changes.
        /// Example: `GitObserver.handleCompletion(model, result);`.
        pub fn handleCompletion(model: *RuntimeModel, completion: CompletionType) void {
            var repository = model.workspaceRepository();
            _ = repository.completeGitProbe(.{
                .workspace = completion.workspace,
                .branch = if (completion.present) completion.branchSlice() else "",
                .dirty = completion.present and completion.dirty,
                .checked_at_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
            });
        }
    };
}
