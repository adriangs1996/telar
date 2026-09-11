const std = @import("std");
const session_name_ops = @import("session_name.zig");
const readers = @import("../../agent/session_readers/session_readers.zig");
const JobType = @import("../../agent/session_readers/Job.zig");
const CompletionType = @import("../../agent/Completion.zig");

/// Binds probing to one application type providing `io`, `select`,
/// `model.agents`, `session_name_probe_in_flight`, `noteSessionChange` and
/// `pumpAll`.
pub fn Type(comptime Application: type) type {
    return struct {
        /// Starts one probe for the stalest due session file, if any.
        ///
        /// ```zig
        /// SessionNameObserver.tick(&application);
        /// ```
        pub fn tick(application: *Application) void {
            if (application.session_name_probe_in_flight) {
                return;
            }

            const now_ms = std.Io.Timestamp.now(application.io, .real).toMilliseconds();
            const watch = application.model.agents.nextSessionFileProbe(now_ms, session_name_ops.probe_interval_ms) orelse return;

            application.session_name_probe_in_flight = true;
            application.select.concurrent(.session_name, readers.probe, .{JobType{ .io = application.io, .watch = watch }}) catch {
                application.session_name_probe_in_flight = false;
                _ = application.model.agents.finishSessionFileProbe(.{ .key = watch.key, .offset = watch.offset }, now_ms);
            };
        }

        /// Applies one probe result and publishes a changed title.
        ///
        /// ```zig
        /// SessionNameObserver.handleCompletion(&application, completion);
        /// ```
        pub fn handleCompletion(application: *Application, completion: CompletionType) void {
            application.session_name_probe_in_flight = false;
            const now_ms = std.Io.Timestamp.now(application.io, .real).toMilliseconds();

            if (application.model.agents.finishSessionFileProbe(completion, now_ms)) {
                application.noteSessionChange();
                application.pumpAll();
            }
        }
    };
}
