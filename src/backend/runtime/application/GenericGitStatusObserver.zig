const source_namespace = @import("git_status.zig");
const worker = @import("../resources/root.zig").git_probe;
/// Binds Git observation to runtime scheduling, not workspace representation.
/// Example: `const GitObserver = Observer(Application);`.
pub fn Type(comptime Application: type) type {
    return struct {
        /// Starts one due probe, rolling back its reservation on scheduling failure.
        /// Example: `GitObserver.tick(application);`.
        pub fn tick(application: *Application) void {
            var repository = application.workspaceRepository();
            const request = repository.reserveGitProbe(.{
                .now_ms = source_namespace.Io.Timestamp.now(application.io, .real).toMilliseconds(),
                .interval_ms = source_namespace.probe_interval_ms,
            }) orelse return;

            application.select.concurrent(.git_status, worker.probe, .{worker.Job{
                .io = application.io,
                .request = request,
            }}) catch repository.cancelGitProbe(request.workspace);
        }

        /// Applies only the outstanding observation and publishes visible changes.
        /// Example: `GitObserver.handleCompletion(application, result);`.
        pub fn handleCompletion(application: *Application, completion: source_namespace.Completion) void {
            var repository = application.workspaceRepository();
            if (repository.completeGitProbe(.{
                .workspace = completion.workspace,
                .branch = if (completion.present) completion.branchSlice() else "",
                .dirty = completion.present and completion.dirty,
                .checked_at_ms = source_namespace.Io.Timestamp.now(application.io, .real).toMilliseconds(),
            })) {
                application.pumpAll();
            }
        }
    };
}
