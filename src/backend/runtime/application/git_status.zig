//! Schedules bounded Git observation through the workspace reservation protocol.

const std = @import("std");
const worker = @import("../resources/root.zig").git_probe;
const Io = std.Io;
pub const Completion = worker.Completion;
pub const probe_interval_ms = worker.probe_interval_ms;

/// Binds Git observation to runtime scheduling, not workspace representation.
/// Example: `const GitObserver = Observer(Application);`.
pub fn Observer(comptime Application: type) type {
    return struct {
        /// Starts one due probe, rolling back its reservation on scheduling failure.
        /// Example: `GitObserver.tick(application);`.
        pub fn tick(application: *Application) void {
            var repository = application.workspaceRepository();
            const request = repository.reserveGitProbe(.{
                .now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds(),
                .interval_ms = probe_interval_ms,
            }) orelse return;

            application.select.concurrent(.git_status, worker.probe, .{worker.Job{
                .io = application.io,
                .request = request,
            }}) catch repository.cancelGitProbe(request.workspace);
        }

        /// Applies only the outstanding observation and publishes visible changes.
        /// Example: `GitObserver.handleCompletion(application, result);`.
        pub fn handleCompletion(application: *Application, completion: Completion) void {
            var repository = application.workspaceRepository();
            if (repository.completeGitProbe(.{
                .workspace = completion.workspace,
                .branch = if (completion.present) completion.branchSlice() else "",
                .dirty = completion.present and completion.dirty,
                .checked_at_ms = Io.Timestamp.now(application.io, .real).toMilliseconds(),
            })) {
                application.pumpAll();
            }
        }
    };
}
